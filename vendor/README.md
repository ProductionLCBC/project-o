# vendor/

Third-party SDKs that cannot be redistributed live here and are git-ignored.

## DeckLink SDK

Download the Blackmagic **Desktop Video SDK** from Blackmagic Design's support site (the same page as Desktop Video; it requires registration) and unpack it so that the macOS headers land at:

```
vendor/DeckLinkSDK/Mac/include/DeckLinkAPI.h
```

Keep the SDK version matched to the Desktop Video driver installed on the test bench. Nothing in `OCore` or the tests depends on it; it is needed only when `OEngine`'s DeckLink module is built (Spec 4 §10, §14). That module will wrap the SDK's COM-style C++ interface in a small Objective-C++ target; the wrapper is the only place C++ is allowed.
