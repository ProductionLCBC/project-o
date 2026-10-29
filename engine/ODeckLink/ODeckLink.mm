// ODeckLink — Spec 4 §10 and §14: the Objective-C++ wrapper over the Blackmagic
// Desktop Video SDK. Built only when vendor/DeckLinkSDK is present
// (Package.swift); otherwise ODeckLinkStub.c stands in.
//
// This file is the only place C++ is allowed. It is filled in when the SDK is
// in vendor/ (Area 4 plan decision 1); until then it is excluded from the
// build and the stub answers every call with ODL_ERR_UNAVAILABLE.

#include "ODeckLink.h"

#if ODL_HAVE_SDK
#error "ODeckLink.mm: the DeckLink wrapper is not written yet; see the Area 4 brief. Remove vendor/DeckLinkSDK to build the stub."
#endif
