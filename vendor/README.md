# vendor/

Third-party SDKs that cannot be redistributed live here and are git-ignored.

## DeckLink SDK

Download the Blackmagic **Desktop Video SDK** from Blackmagic Design's support site (the same page as Desktop Video; it requires registration) and unpack it so that the macOS headers land at:

```
vendor/DeckLinkSDK/Mac/include/DeckLinkAPI.h
```

Keep the SDK version matched to the Desktop Video driver installed on the test bench. Nothing in `OCore` or the tests depends on it. `Package.swift` looks for that header: when it is there, the `ODeckLink` module compiles `engine/ODeckLink/ODeckLink.mm`, the Objective-C++ wrapper of the SDK's COM-style interface behind the C face in `engine/ODeckLink/include/ODeckLink.h` (Spec 4 §10, §14), together with the SDK's dispatch file, which loads `/Library/Frameworks/DeckLinkAPI.framework` at run time; when it is absent, the module compiles `ODeckLinkStub.c`, which reports every card as unavailable so the engine still builds and runs with the SDI sink paused. The wrapper is the only place C++ is allowed. A Mac with the SDK but without the Desktop Video driver behaves like the stub.
