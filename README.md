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
