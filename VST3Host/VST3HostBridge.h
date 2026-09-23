#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MyDAWVST3MetadataCallback)(
    const char* uid,
    const char* name,
    const char* vendor,
    const char* version,
    void* context
);

int MyDAWVST3EnumerateAudioEffects(
    const char* bundlePath,
    MyDAWVST3MetadataCallback callback,
    void* context
);

#ifdef __cplusplus
}
#endif
