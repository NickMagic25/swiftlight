# Pairing and host connections

Swiftlight connects to computers running [Sunshine](https://github.com/LizardByte/Sunshine) or Apollo. Select **Add Computer** and enter the host address, or choose a Bonjour-discovered computer. Custom ports and IPv6 addresses in `[address]:port` form are supported.

Select **Start PIN Pairing**, then enter the displayed PIN in Sunshine or Apollo. Apollo can also provide a one-time `art://` pairing link or separate address, OTP, and passphrase fields. Swiftlight stores the client identity in the macOS login Keychain and does not retain Apollo one-time secrets.

After pairing, Swiftlight loads the computer's application list and available artwork. Select an application to launch it; if it is already running, Swiftlight offers to resume it. **Disconnect** leaves the remote application running. **Quit Remote Application** is a separate confirmed action.

If discovery does not find a computer, add it by address and confirm the host is reachable, pairing is enabled, and the host firewall permits Moonlight connections. For protocol and identity details, see [development host-protocol notes](dev/host-protocol-details.md).
