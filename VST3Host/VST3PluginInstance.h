#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MyDAWVST3Instance MyDAWVST3Instance;

MyDAWVST3Instance* MyDAWVST3Create(
    const char* bundlePath,
    const char* pluginUID,
    double sampleRate,
    int maxFrames
);

int MyDAWVST3ProcessInterleaved(
    MyDAWVST3Instance* instance,
    const float* input,
    float* output,
    int frames,
    int channels
);

int MyDAWVST3GetLatencySamples(const MyDAWVST3Instance* instance);

int MyDAWVST3GetState(
    MyDAWVST3Instance* instance,
    void** data,
    int* size
);

int MyDAWVST3SetState(
    MyDAWVST3Instance* instance,
    const void* data,
    int size
);

int MyDAWVST3AttachEditor(
    MyDAWVST3Instance* instance,
    void* parentView,
    int* width,
    int* height
);

/// attached() 後にプラグインが確定した実際のサイズを取得する。
/// attached() を呼んだ後、プラグインによっては resizeView() で
/// サイズを更新するものがあるため、このAPIで再取得する。
int MyDAWVST3GetEditorSize(
    MyDAWVST3Instance* instance,
    int* width,
    int* height
);

/// attached() 後にプラグインが resizeView() を呼んできたとき、
/// Swift 側のウィンドウを更新するためのコールバックを登録する。
/// context は Swift の Unmanaged ポインタなど任意の値を渡せる。
typedef void (*MyDAWVST3ResizeCallback)(void* context, int width, int height);
void MyDAWVST3SetResizeCallback(
    MyDAWVST3Instance* instance,
    MyDAWVST3ResizeCallback callback,
    void* context
);

void MyDAWVST3RemoveEditor(MyDAWVST3Instance* instance);

void MyDAWVST3FreeState(void* data);
void MyDAWVST3Destroy(MyDAWVST3Instance* instance);

#ifdef __cplusplus
}
#endif
