#include "apple.hpp"
#include "profile_samples.hpp"
#ifdef MAV_VT_EXPERIMENTS
#include "vt_experiment.hpp"
#endif
#include <map>
#include <mutex>
namespace mav {
class VideoToolboxBackend final:public Backend {
    VTDecompressionSessionRef session_=nullptr;CMVideoFormatDescriptionRef format_=nullptr;
    BackendInfo info_;mav_color color_{};Format parsed_;
    mutable std::mutex mutex_;std::map<Work*,std::shared_ptr<Work>> pending_;
#ifdef MAV_VT_EXPERIMENTS
    VTExperiment experiment_;
    bool first_output_=false;
#endif
    static void callback(void* context,void* source,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime,CMTime) {
        // First instruction measuring callback ENTRY, before ownership/map work.
        uint64_t entry=mav_monotonic_time_ns();
        static_cast<VideoToolboxBackend*>(context)->finish(static_cast<Work*>(source),status,flags,image,entry);
    }
    void finish(Work* key,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,uint64_t entry) {
        std::shared_ptr<Work> work;
        {std::lock_guard<std::mutex> l(mutex_);auto it=pending_.find(key);if(it==pending_.end())return;work=std::move(it->second);pending_.erase(it);}
#ifdef MAV_VT_EXPERIMENTS
        experiment_.completed(work.get(),entry,status,flags);
#endif
        if(work->completion_claimed.exchange(true))return;
        BackendOutput out;out.result=vt_result(status);out.status=status;out.callback_ns=entry;
        out.dropped=(flags&kVTDecodeInfo_FrameDropped)!=0;
        if(image&&status==noErr) {
            out.width=static_cast<uint32_t>(CVPixelBufferGetWidth(image));out.height=static_cast<uint32_t>(CVPixelBufferGetHeight(image));out.pixel_format=CVPixelBufferGetPixelFormatType(image);
            bool pixel_matches;
#ifdef MAV_VT_EXPERIMENTS
            bool first_output=false;
            {std::lock_guard<std::mutex> l(mutex_);
                first_output=!first_output_;first_output_=true;
                pixel_matches=experiment_.native_pixel?experiment_.accepts_native_pixel(out.pixel_format):out.pixel_format==info_.pixel_format;
                if(experiment_.native_pixel&&pixel_matches){
                    if(!info_.pixel_format)info_.pixel_format=out.pixel_format;
                    else pixel_matches=out.pixel_format==info_.pixel_format;
                }
            }
            if(first_output)experiment_.log_first_output(session_,image,entry);
#else
            pixel_matches=out.pixel_format==info_.pixel_format;
#endif
            size_t chroma_width=parsed_.chroma==3?out.width:(out.width+1)/2;
            size_t chroma_height=parsed_.chroma==3?out.height:(out.height+1)/2;
            bool planes_match=CVPixelBufferGetPlaneCount(image)==2&&
                CVPixelBufferGetWidthOfPlane(image,0)==out.width&&CVPixelBufferGetHeightOfPlane(image,0)==out.height&&
                CVPixelBufferGetWidthOfPlane(image,1)==chroma_width&&CVPixelBufferGetHeightOfPlane(image,1)==chroma_height;
            if(!pixel_matches||!planes_match||out.width!=parsed_.width||out.height!=parsed_.height) {out.result=MAV_UNSUPPORTED;}
            else {out.image=image;out.color=image_color(image);
#ifdef MAV_VT_EXPERIMENTS
                // image_color's production FourCC list contains linear bi-planar
                // formats only. An allowed experiment preserves signaled range.
                if(experiment_.pixel_format||experiment_.native_pixel){out.color.valid|=MAV_COLOR_RANGE;out.color.full_range=color_.full_range;}
#endif
                attach_missing_color(image,color_);}
        } else if(!status&&work->display&&!out.dropped) {
            // Valid hidden frames are successful no-display. A displayed frame
            // without an image is visible as a drop, never a fake output.
            out.dropped=true;
        }
        work->complete(out);
    }
    int32_t property(CFDictionaryRef supported,CFStringRef key,CFTypeRef value,int32_t& effective) {
        effective=-1;
        if(!supported||!CFDictionaryContainsKey(supported,key))return kVTPropertyNotSupportedErr;
        OSStatus s=VTSessionSetProperty(session_,key,value);
        if(s)return s;
        CFHolder<CFTypeRef> read;OSStatus read_status=VTSessionCopyProperty(session_,key,kCFAllocatorDefault,read.out());
        if(!read_status&&read.value){if(CFGetTypeID(read)==CFBooleanGetTypeID())effective=CFBooleanGetValue(static_cast<CFBooleanRef>(read.value));else if(CFGetTypeID(read)==CFNumberGetTypeID())CFNumberGetValue(static_cast<CFNumberRef>(read.value),kCFNumberIntType,&effective);}
        // A write can succeed even if a read-back isn't available; -1 captures that.
        return s;
    }
public:
    ~VideoToolboxBackend()override{invalidate();}
    mav_result configure(const Format& f,const mav_config& c,const mav_color& color)override {
        invalidate();info_=BackendInfo{};color_=color;parsed_=f;
#ifdef MAV_VT_EXPERIMENTS
        if(!experiment_.load()){experiment_.log_failure(MAV_INVALID_ARGUMENT);return MAV_INVALID_ARGUMENT;}
        first_output_=false;
        experiment_.allowed_format_count=c.pixel_format_count;
        for(uint32_t i=0;i<c.pixel_format_count;++i)experiment_.allowed_formats[i]=c.pixel_formats[i];
        mav_config settings=c;
        if(experiment_.realtime!=-1)settings.realtime=experiment_.realtime;
        if(experiment_.thread_count!=-1)settings.thread_count=static_cast<uint32_t>(experiment_.thread_count);
        if(experiment_.power_efficiency!=-1)settings.power_efficiency=experiment_.power_efficiency;
        if(settings.realtime&&settings.power_efficiency==1){experiment_.error="RealTime and MaximizePowerEfficiency cannot both be enabled";experiment_.log_failure(MAV_UNSUPPORTED);return MAV_UNSUPPORTED;}
#else
        const mav_config& settings=c;
#endif
        mav_capability cap{};cap.struct_size=sizeof(cap);cap.version=MAV_ABI_VERSION;
        auto available=backend_capability(c.codec,cap);
        if(available!=MAV_OK)return available;
        if(c.hardware_policy==MAV_HARDWARE_REQUIRED&&!cap.hardware_decode_candidate)return MAV_UNSUPPORTED;
        OSStatus status=create_format(f,c.codec,color,&format_);info_.last_status=status;if(status)return vt_result(status);
        auto dimensions=CMVideoFormatDescriptionGetDimensions(format_);
        if(dimensions.width!=static_cast<int32_t>(f.width)||dimensions.height!=static_cast<int32_t>(f.height)){invalidate();return MAV_MALFORMED_INPUT;}
        uint32_t pixel=f.chroma==3?
            (f.bit_depth==10?(color.full_range?kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange):(color.full_range?kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)):
            (f.bit_depth==10?(color.full_range?kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange):(color.full_range?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
#ifdef MAV_VT_EXPERIMENTS
        if(!experiment_.select_pixel(pixel)){experiment_.log_failure(MAV_UNSUPPORTED);invalidate();return MAV_UNSUPPORTED;}
#endif
#ifdef MAV_VT_EXPERIMENTS
        if(!experiment_.native_pixel)
#endif
        if(c.pixel_format_count){bool found=false;for(uint32_t i=0;i<c.pixel_format_count;++i)found|=c.pixel_formats[i]==pixel;if(!found){invalidate();return MAV_UNSUPPORTED;}}
        CFHolder<CFMutableDictionaryRef> spec(dictionary()),attrs(dictionary()),surface(dictionary());
        if(@available(macOS 10.9,iOS 17.0,tvOS 17.0,*)) {
            CFDictionarySetValue(spec,c.hardware_policy==MAV_HARDWARE_REQUIRED?kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,kCFBooleanTrue);
        } else {invalidate();return MAV_API_UNAVAILABLE;}
#ifdef MAV_VT_EXPERIMENTS
        if(!experiment_.native_pixel)
#endif
        number(attrs,kCVPixelBufferPixelFormatTypeKey,static_cast<int>(pixel));
#ifdef MAV_VT_EXPERIMENTS
        if(experiment_.iosurface)
#endif
        CFDictionarySetValue(attrs,kCVPixelBufferIOSurfacePropertiesKey,surface);
#ifdef MAV_VT_EXPERIMENTS
        if(experiment_.metal)
#endif
        CFDictionarySetValue(attrs,kCVPixelBufferMetalCompatibilityKey,kCFBooleanTrue);
        VTDecompressionOutputCallbackRecord cb{callback,this};
        status=VTDecompressionSessionCreate(kCFAllocatorDefault,format_,spec,attrs,&cb,&session_);info_.last_status=status;
        if(status){invalidate();return vt_result(status);}
        CFHolder<CFTypeRef> hardware;
        if(@available(macOS 10.9,iOS 17.0,tvOS 17.0,*))status=VTSessionCopyProperty(session_,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,kCFAllocatorDefault,hardware.out());
        if(!status&&hardware.value&&CFGetTypeID(hardware)==CFBooleanGetTypeID())info_.hardware=CFBooleanGetValue(static_cast<CFBooleanRef>(hardware.value));
        if(c.hardware_policy==MAV_HARDWARE_REQUIRED&&(!info_.hardware||status)){info_.last_status=status;invalidate();return MAV_UNSUPPORTED;}
        info_.pixel_format=pixel;
#ifdef MAV_VT_EXPERIMENTS
        if(experiment_.native_pixel)info_.pixel_format=0;
#endif
        CFHolder<CFDictionaryRef> properties;status=VTSessionCopySupportedPropertyDictionary(session_,properties.out());
        if(status){info_.realtime_status=status;info_.power_status=status;info_.thread_status=status;}
        else {
            info_.realtime_status=property(properties,kVTDecompressionPropertyKey_RealTime,settings.realtime?kCFBooleanTrue:kCFBooleanFalse,info_.realtime_effective);
            if(settings.power_efficiency!=-1)info_.power_status=property(properties,kVTDecompressionPropertyKey_MaximizePowerEfficiency,settings.power_efficiency?kCFBooleanTrue:kCFBooleanFalse,info_.power_effective);
            else {CFHolder<CFTypeRef> v;auto s=VTSessionCopyProperty(session_,kVTDecompressionPropertyKey_MaximizePowerEfficiency,kCFAllocatorDefault,v.out());info_.power_status=s;if(!s&&v.value&&CFGetTypeID(v)==CFBooleanGetTypeID())info_.power_effective=CFBooleanGetValue(static_cast<CFBooleanRef>(v.value));}
            if(settings.thread_count){int n=settings.thread_count;CFHolder<CFNumberRef> value(CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&n));info_.thread_status=property(properties,kVTDecompressionPropertyKey_ThreadCount,value,info_.thread_effective);}
        }
#ifdef MAV_VT_EXPERIMENTS
        experiment_.log_session(session_,c,settings,info_,properties,status);
#endif
        return MAV_OK;
    }
    void submit(std::shared_ptr<Work> w)override {
        try {
            CFHolder<CMSampleBufferRef> sample;auto status=create_sample(w,format_,sample.out());
            if(status){BackendOutput o;o.result=vt_result(status);o.status=status;w->complete(o);return;}
            {std::lock_guard<std::mutex> l(mutex_);pending_.emplace(w.get(),w);}
            VTDecodeInfoFlags flags=0;
#ifdef MAV_VT_EXPERIMENTS
            VTDecodeFrameFlags decode_flags=experiment_.asynchronous?kVTDecodeFrame_EnableAsynchronousDecompression:0;
#else
            const VTDecodeFrameFlags decode_flags=kVTDecodeFrame_EnableAsynchronousDecompression;
#endif
            w->submit_ns.store(mav_monotonic_time_ns());
#ifdef MAV_VT_EXPERIMENTS
            experiment_.begin(w.get(),w->submit_ns.load());
#endif
            status=VTDecompressionSessionDecodeFrame(session_,sample,decode_flags,w.get(),&flags);
            w->return_ns.store(mav_monotonic_time_ns());
#ifdef MAV_VT_EXPERIMENTS
            experiment_.returned(w.get(),w->return_ns.load(),status);
#endif
            // SDK guarantees no callback for a synchronous error. Map removal
            // is idempotent and ownership also survives an inline success.
            if(status)finish(w.get(),status,flags,nullptr,0);
            else if((flags&kVTDecodeInfo_FrameDropped)&&!w->completion_claimed.exchange(true)){
                // Resolve public capacity now, but KEEP the source context in
                // pending_ until its promised callback or controlled drain.
                // Otherwise a late callback could alias a reused Work address.
                BackendOutput dropped;dropped.dropped=true;w->complete(dropped);
            }
        }catch(const std::bad_alloc&){BackendOutput o;o.result=MAV_OUT_OF_MEMORY;w->complete(o);}
    }
    mav_result drain()override {
        OSStatus status=session_?VTDecompressionSessionWaitForAsynchronousFrames(session_):noErr;
        // The library contract does not depend on callbacks being emitted for
        // every decoder edge case. Controlled drain resolves any missing ones.
        for(;;){Work* w;{std::lock_guard<std::mutex> l(mutex_);if(pending_.empty())break;w=pending_.begin()->first;}finish(w,status?status:kVTVideoDecoderMalfunctionErr,0,nullptr,0);}
        return vt_result(status);
    }
    void invalidate()override {
        if(session_){drain();VTDecompressionSessionInvalidate(session_);CFRelease(session_);session_=nullptr;}
        if(format_){CFRelease(format_);format_=nullptr;}
    }
    BackendInfo info()const override{
#ifdef MAV_VT_EXPERIMENTS
        std::lock_guard<std::mutex> l(mutex_);
#endif
        return info_;
    }
};
std::unique_ptr<Backend> make_backend(){return std::make_unique<VideoToolboxBackend>();}
mav_result backend_capability(mav_codec codec,mav_capability& c) {
    c.codec=codec;c.api_available=0;c.hardware_decode_candidate=0;
    if(codec==MAV_CODEC_AV1){if(@available(macOS 14.0,iOS 17.0,tvOS 17.0,*))c.api_available=1;}
    else c.api_available=1;
    if(!c.api_available)return MAV_API_UNAVAILABLE;
    c.hardware_decode_candidate=VTIsHardwareDecodeSupported(codec==MAV_CODEC_AV1?kCMVideoCodecType_AV1:kCMVideoCodecType_HEVC);
    return MAV_OK;
}
mav_result backend_profile_capability(mav_codec codec,uint32_t depth,uint32_t chroma,mav_capability& cap) {
    auto available=backend_capability(codec,cap);
    bool candidate=cap.hardware_decode_candidate!=0;
    cap.hardware_decode_candidate=0;
    if(available!=MAV_OK)return available;
    if(!candidate)return MAV_UNSUPPORTED;
    const uint8_t* bytes=nullptr;size_t size=0;
    using namespace profile_samples;
#define MAV_PROFILE_SAMPLE(name) do {bytes=name;size=sizeof(name);} while(0)
    if(codec==MAV_CODEC_HEVC) {
        if(chroma==3){if(depth==10)MAV_PROFILE_SAMPLE(hevc_rext10_444);else MAV_PROFILE_SAMPLE(hevc_rext8_444);}
        else {if(depth==10)MAV_PROFILE_SAMPLE(hevc_main10_420);else MAV_PROFILE_SAMPLE(hevc_main8_420);}
    } else {
        if(chroma==3){if(depth==10)MAV_PROFILE_SAMPLE(av1_high10_444);else MAV_PROFILE_SAMPLE(av1_high8_444);}
        else {if(depth==10)MAV_PROFILE_SAMPLE(av1_main10_420);else MAV_PROFILE_SAMPLE(av1_main8_420);}
    }
#undef MAV_PROFILE_SAMPLE
    struct Probe {
        uint32_t chroma=0,depth=0;std::atomic<unsigned> callbacks{0};bool validated=false;
    } probe;probe.chroma=chroma;probe.depth=depth;
    mav_config config;mav_config_default(&config,codec);
    config.hardware_policy=MAV_HARDWARE_REQUIRED;config.max_frames_in_flight=1;
    config.width=1280;config.height=720;config.bit_depth=depth;config.chroma_format=chroma;
    config.pixel_format_count=2;
    config.pixel_formats[0]=chroma==3?
        (depth==10?kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange):
        (depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    config.pixel_formats[1]=chroma==3?
        (depth==10?kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:kCVPixelFormatType_444YpCbCr8BiPlanarFullRange):
        (depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    config.context=&probe;
    config.completion=[](void* context,const mav_completion* completion) {
        auto& p=*static_cast<Probe*>(context);auto image=completion->pixel_buffer;
        if(completion->status==MAV_COMPLETION_OUTPUT&&completion->result==MAV_OK&&completion->hardware_accelerated&&
            completion->bit_depth==p.depth&&completion->width==1280&&completion->height==720&&image&&CVPixelBufferGetPlaneCount(image)==2) {
            uint32_t expected=p.chroma==3?
                (p.depth==10?kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange):
                (p.depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            p.validated=completion->pixel_format==expected&&CVPixelBufferGetPixelFormatType(image)==expected&&
                CVPixelBufferGetWidthOfPlane(image,0)==1280&&CVPixelBufferGetHeightOfPlane(image,0)==720&&
                CVPixelBufferGetWidthOfPlane(image,1)==(p.chroma==3?1280:640)&&CVPixelBufferGetHeightOfPlane(image,1)==(p.chroma==3?720:360);
        }
        p.callbacks.fetch_add(1,std::memory_order_release);
    };
    mav_decoder* decoder=nullptr;auto result=mav_decoder_create(&config,&decoder);
    if(result!=MAV_OK)return result;
    // Private decoder: no concurrent controls, and the public wrapper rejects
    // callback reentrancy before creating this owner. Destruction always drains.
    std::unique_ptr<mav_decoder,decltype(&mav_decoder_destroy)> owner(decoder,mav_decoder_destroy);
    mav_access_unit unit;mav_access_unit_default(&unit,codec);mav_span span{bytes,size};
    unit.spans=&span;unit.span_count=1;unit.flags=MAV_INPUT_RANDOM_ACCESS;
    result=mav_decoder_submit_copy(decoder,&unit);
    if(result!=MAV_OK)return result;
    result=mav_decoder_drain(decoder);
    if(result!=MAV_OK)return result;
    mav_metrics metrics{};metrics.struct_size=sizeof(metrics);metrics.version=MAV_ABI_VERSION;
    result=mav_decoder_get_metrics(decoder,&metrics);
    if(result!=MAV_OK)return result;
    if(probe.callbacks.load(std::memory_order_acquire)!=1||!probe.validated||!metrics.hardware_validated)return MAV_UNSUPPORTED;
    cap.hardware_decode_candidate=1;
    return MAV_OK;
}
void retain_pixel(mav_pixel_buffer p){CVPixelBufferRetain(p);}
void release_pixel(mav_pixel_buffer p){CVPixelBufferRelease(p);}
}
