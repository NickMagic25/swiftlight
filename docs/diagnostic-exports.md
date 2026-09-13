# Stream diagnostic exports

After disconnecting, choose **Stream → Export Last Stream Diagnostics…**, or use the same action in the selected computer's options menu. Save the JSON file before quitting Swiftlight; the last report is retained in memory only until the next completed connection attempt or app exit.

The export describes the completed attempt, including selected settings, outcome or failure category, a bounded recent statistics timeline, and decoder, renderer, network, and audio counters. Failed connection attempts are included when they produce a completed report.

The export intentionally excludes pairing credentials, private keys, certificate data, host addresses, application names, input events, and media. Review the file before sharing it if your environment includes other identifying information in optional system metadata.

For the complete schema and validation evidence, see [development diagnostic-export notes](dev/diagnostic-exports-schema.md).
