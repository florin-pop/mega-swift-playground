# mega-swift-playground
Swift (Xcode) playground showing how to download and decrypt a file from mega.nz

## Motivation
While working on a download manager I wanted to add the ability to download files from Mega.nz, but the [official iOS SDK](https://github.com/meganz/iOS) has a large footprint and many dependencies. This playground only depends on [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift).

## Inspiration

The playground uses the decryption algorithm from the *JDownloader* Mega plugin source code which is officially hosted at [svn://svn.jdownloader.org/jdownloader](svn://svn.jdownloader.org/jdownloader).

The regular expressions for detecting the file ID and Key from the URL are from the *megatools* project which is officially hosted at [http://megous.com/git/megatools](http://megous.com/git/megatools).


## Try it out
```
git clone git@github.com:florin-pop/mega-swift-playground.git
cd mega-swift-playground/
git submodule init
git submodule update
```

Open the workspace and run to the last line. Inspect the decrypted image. Enjoy.
