# Direct SOTER diagnostic probe (arm64 Android)

Standalone diagnostic, not a KernelSU module. No service restarts, imports,
generation, deletion or retries. It calls SOTER directly, bypassing CryptoEng.

Supported protocol is intentionally limited to the supplied firmware:
`vendor.qti.hardware.soter.ISoter/default`, stable AIDL v1, interface hash
`81832c92aa802927e98f3bf426e95b03e5d7f5e6`. A different version/hash aborts
before the verification transaction. This is a diagnostic compatibility guard,
not a device-model condition in the SoterFix module.

The hash/version transactions (16777214/16777215), verification transaction 14,
flag 0x10000000, and output int32 are checked against the supplied generated
`vendor.qti.hardware.soter-V1-ndk.so`. HAL verification is checked in
`vendor/lib64/hw/vendor.qti.hardware.soter-impl.so`, function at 0xb040:
it logs entry, sends command 0x102 through QSEECom_send_cmd, and returns an
output enum separately from the Binder status envelope.

Run as root from /data/local/tmp. Every invocation gets a fresh Binder handle.
A 15-second alarm bounds the complete probe. No fallback to a fake result.

- DIRECT_VERIFY_OK: Binder reply OK and actual verification result 0.
- DIRECT_VERIFY_FAILED: Binder reply OK but actual verification result nonzero.
- TRANSPORT_ERROR / BINDER_REPLY_ERROR / MALFORMED_REPLY: key health UNKNOWN.
- SERVICE_UNAVAILABLE_OR_ACCESS_DENIED: unavailable service or lookup denied;
  this does not establish key failure.
- UNSUPPORTED_INTERFACE_VERSION_OR_HASH: no verification performed.

Run once after reboot before Action, then again after Action. Keep both outputs.
An actual result 0 verifies this OEM method for that moment; it does not establish
all payment flows, permanent repair, or correctness of unrelated keys.

This build has host mock tests for error/result separation, malformed replies,
missing service and interface mismatch. Compilation is not device validation.
It has not yet run on the physical phone. Do not interpret a probe failure as PASS.

AOSP ABI references (Android 15):
- https://android.googlesource.com/platform/frameworks/native/+/refs/heads/android15-release/libs/binder/ndk/include_ndk/android/binder_ibinder.h
- https://android.googlesource.com/platform/frameworks/native/+/refs/heads/android15-release/libs/binder/ndk/include_ndk/android/binder_parcel.h
- https://android.googlesource.com/platform/frameworks/native/+/refs/heads/android15-release/libs/binder/ndk/include_ndk/android/binder_status.h
- https://android.googlesource.com/platform/frameworks/native/+/refs/heads/android15-release/libs/binder/ndk/include_platform/android/binder_manager.h
