# Audio and Spatial Audio

Open **Settings → Audio**, choose the host channel layout and local output mode, then save the choice for the current computer or as a global default. Reconnect after changing audio settings.

| Setting | Choices |
| --- | --- |
| Audio channels | Stereo, 5.1 Surround, or 7.1 Surround |
| Audio output | Direct, or System Spatial Audio for 5.1/7.1 |
| Play audio on host | Also asks the host to play the stream locally; disabled by default |

Choose **Stereo + Direct** when the game already provides a headphone or binaural mix. For client-side surround virtualization, configure the host and game for 5.1 or 7.1 speakers, select the matching channel count, and choose **System Spatial Audio**. For physical surround speakers, choose the matching channels with **Direct**.

With compatible AirPods, use the macOS AirPods menu to choose **Off**, **Fixed**, or **Head Tracked** when those controls are available. Availability depends on the Mac, AirPods, macOS, and content. Swiftlight supplies channel-based surround audio; it does not claim Dolby Atmos object passthrough or custom head tracking.

Audio settings are saved per computer or as global defaults. Stereo always uses Direct output, even if an inconsistent saved combination is encountered. Audio output-device changes can recover without reconnecting video, but reconnect if playback does not resume.

For implementation details and physical acceptance status, see [development audio notes](dev/audio-implementation.md).
