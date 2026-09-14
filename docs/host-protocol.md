# Pairing and host connections

Swiftlight connects to computers running [Sunshine](https://github.com/LizardByte/Sunshine) or Apollo. Select **Add Computer** and enter the host address, or choose a Bonjour-discovered computer. Custom ports and IPv6 addresses in `[address]:port` form are supported.

Select **Start PIN Pairing**, then enter the displayed PIN in Sunshine or Apollo. Apollo can also provide a one-time `art://` pairing link or separate address, OTP, and passphrase fields. Swiftlight stores the client identity in the macOS login Keychain and does not retain Apollo one-time secrets.

After pairing, Swiftlight loads the computer's application list and available artwork. While you are not streaming, it checks the selected computer about every five seconds and updates the **Resume** banner on the running app. Checks pause during pairing, host controls, streaming, and Mac sleep, then resume automatically. Temporary connection failures retry quietly; **Refresh** still reloads the complete library on demand.

Select an application to launch it; if it is already running, Swiftlight resumes it. Right-click the running app and choose **Quit Remote Application…** to close it on the host. Selecting a different app offers **Quit and Start**, which closes the current app and starts your selection after the host confirms it has quit. If the running app changes while that confirmation is open, Swiftlight asks again. A rejected quit leaves the new app unstarted. **Disconnect** leaves the remote application running.

If discovery does not find a computer, add it by address and confirm the host is reachable, pairing is enabled, and the host firewall permits Moonlight connections. For protocol and identity details, see [development host-protocol notes](dev/host-protocol-details.md).
