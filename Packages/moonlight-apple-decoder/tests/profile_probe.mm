#include "moonlight_apple_video/decoder.h"
#include "profile_samples.hpp"
#import <Metal/Metal.h>
#include <CoreVideo/CoreVideo.h>
#include <atomic>
#include <cstdlib>
#include <iostream>
#define CHECK(expression) do {if(!(expression)){std::cerr<<__LINE__<<": " #expression "\n";return false;}} while(0)
struct Fixture {const char* name;mav_codec codec;uint32_t depth,chroma;const uint8_t* bytes;size_t size;};
struct Sink {
    std::atomic<unsigned> callbacks{0};mav_completion completion{};CVPixelBufferRef retained=nullptr;
    ~Sink(){if(retained)CVPixelBufferRelease(retained);}
    static void output(void* context,const mav_completion* completion){
        auto& self=*static_cast<Sink*>(context);self.completion=*completion;
        if(completion->pixel_buffer)self.retained=CVPixelBufferRetain(completion->pixel_buffer);
        self.callbacks.fetch_add(1,std::memory_order_release);
    }
};
static mav_result submit(mav_decoder* decoder,const Fixture& fixture) {
    mav_access_unit unit;mav_access_unit_default(&unit,fixture.codec);mav_span span{fixture.bytes,fixture.size};
    unit.spans=&span;unit.span_count=1;unit.flags=MAV_INPUT_RANDOM_ACCESS;
    return mav_decoder_submit_copy(decoder,&unit);
}
static bool decode(const Fixture& fixture) {
    Sink sink;mav_config config;mav_config_default(&config,fixture.codec);config.completion=Sink::output;config.context=&sink;
    config.width=1280;config.height=720;config.bit_depth=fixture.depth;config.chroma_format=fixture.chroma;
    config.hardware_policy=MAV_HARDWARE_REQUIRED;
    mav_decoder* decoder=nullptr;CHECK(mav_decoder_create(&config,&decoder)==MAV_OK);
    auto result=submit(decoder,fixture);auto drained=mav_decoder_drain(decoder);
    mav_metrics metrics{};metrics.struct_size=sizeof(metrics);metrics.version=MAV_ABI_VERSION;
    auto measured=mav_decoder_get_metrics(decoder,&metrics);
    auto reset=mav_decoder_reset(decoder);auto destroyed=mav_decoder_destroy(decoder);
    CHECK(result==MAV_OK&&drained==MAV_OK&&measured==MAV_OK&&reset==MAV_OK&&destroyed==MAV_OK);
    CHECK(sink.callbacks.load(std::memory_order_acquire)==1&&sink.completion.status==MAV_COMPLETION_OUTPUT);
    CHECK(sink.completion.hardware_accelerated&&metrics.hardware_validated&&metrics.accepted==1&&metrics.completed==1);
    CHECK(sink.completion.bit_depth==fixture.depth&&sink.retained&&CVPixelBufferGetPlaneCount(sink.retained)==2);
    uint32_t pixel=fixture.chroma==3?
        (fixture.depth==10?kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange):
        (fixture.depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CHECK(sink.completion.pixel_format==pixel&&CVPixelBufferGetPixelFormatType(sink.retained)==pixel);
    CHECK(CVPixelBufferGetWidth(sink.retained)==1280&&CVPixelBufferGetHeight(sink.retained)==720);
    CHECK(CVPixelBufferGetWidthOfPlane(sink.retained,1)==(fixture.chroma==3?1280:640));
    CHECK(CVPixelBufferGetHeightOfPlane(sink.retained,1)==(fixture.chroma==3?720:360));
    CHECK(CVPixelBufferGetIOSurface(sink.retained));
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();CHECK(device);
    CVMetalTextureCacheRef cache=nullptr;CHECK(CVMetalTextureCacheCreate(nullptr,nullptr,device,nullptr,&cache)==kCVReturnSuccess);
    bool imported=true;
    for(size_t plane=0;plane<2;++plane) {
        MTLPixelFormat format=plane==0?(fixture.depth==10?MTLPixelFormatR16Unorm:MTLPixelFormatR8Unorm):(fixture.depth==10?MTLPixelFormatRG16Unorm:MTLPixelFormatRG8Unorm);
        CVMetalTextureRef texture=nullptr;
        auto status=CVMetalTextureCacheCreateTextureFromImage(nullptr,cache,sink.retained,nullptr,format,
            CVPixelBufferGetWidthOfPlane(sink.retained,plane),CVPixelBufferGetHeightOfPlane(sink.retained,plane),plane,&texture);
        imported&=status==kCVReturnSuccess&&texture&&CVMetalTextureGetTexture(texture);
        if(texture)CFRelease(texture);
    }
    CFRelease(cache);CHECK(imported);
    // Prohibit either an explicit source-profile mismatch or a caller FourCC
    // list that would request 4:2:0 conversion for a 4:4:4 sequence.
    if(fixture.chroma==3)for(bool mismatched_chroma:{false,true}) {
        Sink rejected;config.context=&rejected;
        config.chroma_format=mismatched_chroma?1:3;
        config.pixel_format_count=1;config.pixel_formats[0]=fixture.depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        CHECK(mav_decoder_create(&config,&decoder)==MAV_OK);
        auto rejected_result=submit(decoder,fixture);auto rejected_destroy=mav_decoder_destroy(decoder);
        CHECK(rejected_result==MAV_UNSUPPORTED&&rejected_destroy==MAV_OK&&rejected.callbacks.load()==0);
    }
    std::cout<<fixture.name<<": actual hardware canonical output, full requested chroma, retained Metal import after reset/destroy\n";
    return true;
}
int main(){@autoreleasepool {
    if(!std::getenv("MAV_PROFILE_HARDWARE_TESTS")||std::string(std::getenv("MAV_PROFILE_HARDWARE_TESTS"))!="1") {
        std::cout<<"SKIP: set MAV_PROFILE_HARDWARE_TESTS=1 for sequential native profile probes\n";return 77;
    }
    using namespace mav::profile_samples;
#define FIXTURE(name,codec,depth,chroma) {#name,MAV_CODEC_##codec,depth,chroma,name,sizeof(name)}
    Fixture fixtures[]={FIXTURE(hevc_main8_420,HEVC,8,1),FIXTURE(hevc_main10_420,HEVC,10,1),
        FIXTURE(av1_main8_420,AV1,8,1),FIXTURE(av1_main10_420,AV1,10,1),
        FIXTURE(hevc_rext8_444,HEVC,8,3),FIXTURE(hevc_rext10_444,HEVC,10,3),
        FIXTURE(av1_high8_444,AV1,8,3),FIXTURE(av1_high10_444,AV1,10,3)};
#undef FIXTURE
    bool control[2][2]{};unsigned validated=0,unavailable=0;
    const char* required=std::getenv("MAV_PROFILE_REQUIRE_HEVC444");bool require_hevc444=required&&std::string(required)=="1";
    for(const auto& fixture:fixtures) {
        unsigned codec=fixture.codec==MAV_CODEC_AV1,depth=fixture.depth==10;
        if(fixture.chroma==3&&!control[codec][depth]){
            std::cout<<fixture.name<<": UNAVAILABLE (matching 4:2:0 hardware control unavailable)\n";
            if(require_hevc444&&fixture.codec==MAV_CODEC_HEVC)return 1;
            ++unavailable;continue;
        }
        mav_capability cap{};cap.struct_size=sizeof(cap);cap.version=MAV_ABI_VERSION;
        auto result=mav_query_profile_capability(fixture.codec,fixture.depth,fixture.chroma,&cap);
        std::cout<<fixture.name<<": profile_query="<<mav_result_string(result)<<" api="<<cap.api_available<<" validated_candidate="<<cap.hardware_decode_candidate<<"\n";
        if(result!=MAV_OK||!cap.hardware_decode_candidate) {
            if(cap.hardware_decode_candidate){std::cerr<<"failed query must clear candidate\n";return 1;}
            if(require_hevc444&&fixture.codec==MAV_CODEC_HEVC&&fixture.chroma==3){std::cerr<<"required HEVC 4:4:4 profile unavailable\n";return 1;}
            ++unavailable;continue;
        }
        if(!decode(fixture))return 1;
        if(fixture.chroma==1)control[codec][depth]=true;
        ++validated;
    }
    std::cout<<"Validated profiles="<<validated<<"; unavailable profiles="<<unavailable<<" (availability is device-specific)\n";
    if(!validated)return 77;
    return 0;
}}
