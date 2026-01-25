# DF Downloader

This is a small shell script to assist with downloading [Digital Foundry videos](https://www.patreon.com/digitalfoundry).

## Requirements
* [Gum](https://github.com/charmbracelet/gum)
* wget

## Usage
1. Set your download directory as an environment variable `DF_DOWNLOAD_DIR`.
1. Use the utility like so `./df-download.sh -f https://<cdn_link>` with `-f` allowing you to download in the foreground.

The script strips the secure link from the file and downloads it to your specified directory.
You can also pass multiple URLs to queue several downloads.

Processor mode (run with --processor) is non-interactive:
When processing the queue the script will not prompt for confirmations (for example, when a destination file already exists). By default, processing will skip re-downloading existing files and will remove the item from the queue. If you want the processor to automatically overwrite existing files in a non-interactive run, set the environment variable `DF_ASSUME_YES=1` when invoking the script.
