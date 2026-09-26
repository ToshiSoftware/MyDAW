#include "VST3PluginInstance.h"

#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/common/memorystream.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/vstspeaker.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Forward declaration
struct MyDAWVST3Instance;

class MyDAWVST3PlugFrame : public Steinberg::IPlugFrame {
public:
    MyDAWVST3Instance* owner = nullptr;

    Steinberg::tresult PLUGIN_API resizeView(
        Steinberg::IPlugView*,
        Steinberg::ViewRect* newSize
    ) override;

    Steinberg::tresult PLUGIN_API queryInterface(
        const Steinberg::TUID iid,
        void** obj
    ) override {
        if (!obj) {
            return Steinberg::kInvalidArgument;
        }
        if (Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::IPlugFrame::iid) ||
            Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::FUnknown::iid)) {
            *obj = this;
            addRef();
            return Steinberg::kResultTrue;
        }
        *obj = nullptr;
        return Steinberg::kNoInterface;
    }

    Steinberg::uint32 PLUGIN_API addRef() override { return 1000; }
    Steinberg::uint32 PLUGIN_API release() override { return 1000; }

    int width = 0;
    int height = 0;
};

struct MyDAWVST3Instance {
    VST3::Hosting::Module::Ptr module;
    std::unique_ptr<Steinberg::Vst::PlugProvider> provider;
    std::unique_ptr<Steinberg::Vst::HostApplication> hostApplication;
    Steinberg::IPtr<Steinberg::Vst::IComponent> component;
    Steinberg::IPtr<Steinberg::Vst::IEditController> controller;
    Steinberg::FUnknownPtr<Steinberg::Vst::IAudioProcessor> processor;
    Steinberg::IPtr<Steinberg::IPlugView> editorView;
    std::unique_ptr<MyDAWVST3PlugFrame> plugFrame;
    int maxFrames = 0;
    std::vector<float> inputLeft;
    std::vector<float> inputRight;
    std::vector<float> outputLeft;
    std::vector<float> outputRight;
    float* inputChannels[2] = {nullptr, nullptr};
    float* outputChannels[2] = {nullptr, nullptr};
    Steinberg::Vst::ProcessContext processContext{};
    double sampleRate = 44100.0;
    std::mutex processMutex;

    // resizeView コールバック（Swift 側のウィンドウを更新するため）
    MyDAWVST3ResizeCallback resizeCallback = nullptr;
    void* resizeContext = nullptr;
};

// resizeView の実装（MyDAWVST3Instance が定義された後に記述）
Steinberg::tresult PLUGIN_API MyDAWVST3PlugFrame::resizeView(
    Steinberg::IPlugView*,
    Steinberg::ViewRect* newSize
) {
    if (!newSize) {
        return Steinberg::kInvalidArgument;
    }
    int newWidth  = newSize->getWidth();
    int newHeight = newSize->getHeight();
    width  = newWidth;
    height = newHeight;

    // Swift 側コールバックが登録されていればウィンドウ更新を通知する
    if (owner && owner->resizeCallback) {
        owner->resizeCallback(owner->resizeContext, newWidth, newHeight);
    }
    return Steinberg::kResultOk;
}

MyDAWVST3Instance* MyDAWVST3Create(
    const char* bundlePath,
    const char* pluginUID,
    double sampleRate,
    int maxFrames
) {
    if (!bundlePath || !pluginUID || sampleRate <= 0.0 || maxFrames <= 0) {
        return nullptr;
    }

    std::string error;
    auto module = VST3::Hosting::Module::create(bundlePath, error);
    if (!module) {
        return nullptr;
    }

    auto uid = VST3::UID::fromString(std::string(pluginUID));
    if (!uid) {
        return nullptr;
    }

    VST3::Hosting::ClassInfo selectedClass;
    bool found = false;
    for (const auto& classInfo : module->getFactory().classInfos()) {
        if (classInfo.category() == kVstAudioEffectClass && classInfo.ID() == *uid) {
            selectedClass = classInfo;
            found = true;
            break;
        }
    }
    if (!found) {
        return nullptr;
    }

    auto instance = std::make_unique<MyDAWVST3Instance>();
    instance->module = std::move(module);
    instance->hostApplication = std::make_unique<Steinberg::Vst::HostApplication>();
    Steinberg::Vst::PluginContextFactory::instance().setPluginContext(
        instance->hostApplication.get()
    );
    instance->provider = std::make_unique<Steinberg::Vst::PlugProvider>(
        instance->module->getFactory(), selectedClass, true
    );
    if (!instance->provider->initialize()) {
        return nullptr;
    }

    instance->component  = instance->provider->getComponentPtr();
    instance->controller = instance->provider->getControllerPtr();
    instance->processor  = Steinberg::FUnknownPtr<Steinberg::Vst::IAudioProcessor>(
        instance->component
    );
    if (!instance->component || !instance->processor) {
        return nullptr;
    }

    if (instance->component->activateBus(
            Steinberg::Vst::kAudio,
            Steinberg::Vst::kInput,
            0,
            true
        ) != Steinberg::kResultTrue ||
        instance->component->activateBus(
            Steinberg::Vst::kAudio,
            Steinberg::Vst::kOutput,
            0,
            true
        ) != Steinberg::kResultTrue) {
        return nullptr;
    }

    Steinberg::Vst::SpeakerArrangement inputArrangement  = Steinberg::Vst::SpeakerArr::kStereo;
    Steinberg::Vst::SpeakerArrangement outputArrangement = Steinberg::Vst::SpeakerArr::kStereo;
    instance->processor->setBusArrangements(&inputArrangement, 1, &outputArrangement, 1);

    Steinberg::Vst::ProcessSetup setup {
        Steinberg::Vst::kRealtime,
        Steinberg::Vst::kSample32,
        maxFrames,
        sampleRate
    };
    if (instance->processor->setupProcessing(setup) != Steinberg::kResultOk ||
        instance->component->setActive(true) != Steinberg::kResultOk ||
        instance->processor->setProcessing(true) != Steinberg::kResultOk) {
        return nullptr;
    }

    instance->maxFrames = maxFrames;
    instance->sampleRate = sampleRate;
    instance->processContext.sampleRate = sampleRate;
    instance->processContext.state = Steinberg::Vst::ProcessContext::kPlaying;
    instance->inputLeft.resize(maxFrames);
    instance->inputRight.resize(maxFrames);
    instance->outputLeft.resize(maxFrames);
    instance->outputRight.resize(maxFrames);
    return instance.release();
}

int MyDAWVST3AttachEditor(
    MyDAWVST3Instance* instance,
    void* parentView,
    int* width,
    int* height
) {
    if (!instance || !parentView || !instance->controller || !width || !height) {
        return -1;
    }

    if (!instance->editorView) {
        instance->editorView = Steinberg::owned(
            instance->controller->createView(Steinberg::Vst::ViewType::kEditor)
        );
        if (!instance->editorView) {
            return -2;
        }
        auto frame = std::make_unique<MyDAWVST3PlugFrame>();
        frame->owner = instance;
        instance->plugFrame = std::move(frame);
    }

    if (instance->editorView->isPlatformTypeSupported(Steinberg::kPlatformTypeNSView) !=
        Steinberg::kResultTrue) {
        return -4;
    }
    if (instance->editorView->setFrame(instance->plugFrame.get()) != Steinberg::kResultOk) {
        return -5;
    }

    // attached() を先に呼ぶ。
    // プラグインによっては attached() が完了して初めてサイズが確定するため、
    // getSize() は attached() の後で呼ぶ。
    if (instance->editorView->attached(parentView, Steinberg::kPlatformTypeNSView) !=
        Steinberg::kResultTrue) {
        instance->editorView->setFrame(nullptr);
        return -6;
    }

    // attached() 後に getSize() を呼んでサイズを取得する。
    // プラグインが attached() 中に resizeView() を呼んでいた場合は
    // plugFrame に記録された値が最新となるため、それを優先する。
    Steinberg::ViewRect viewRect;
    if (instance->editorView->getSize(&viewRect) == Steinberg::kResultTrue) {
        int w = viewRect.getWidth();
        int h = viewRect.getHeight();
        // plugFrame 側の resizeView() 経由の値があればそちらを優先
        if (instance->plugFrame->width  > 0) { w = instance->plugFrame->width; }
        if (instance->plugFrame->height > 0) { h = instance->plugFrame->height; }
        *width  = std::max(320, w);
        *height = std::max(240, h);
    } else {
        // getSize() が失敗した場合は plugFrame の値か最低限のサイズ
        *width  = std::max(320, instance->plugFrame->width);
        *height = std::max(240, instance->plugFrame->height);
    }

    return 0;
}

int MyDAWVST3GetEditorSize(
    MyDAWVST3Instance* instance,
    int* width,
    int* height
) {
    if (!instance || !width || !height || !instance->editorView) {
        return -1;
    }
    Steinberg::ViewRect viewRect;
    if (instance->editorView->getSize(&viewRect) != Steinberg::kResultTrue) {
        return -2;
    }
    int w = viewRect.getWidth();
    int h = viewRect.getHeight();
    if (instance->plugFrame->width  > 0) { w = instance->plugFrame->width; }
    if (instance->plugFrame->height > 0) { h = instance->plugFrame->height; }
    *width  = std::max(320, w);
    *height = std::max(240, h);
    return 0;
}

void MyDAWVST3SetResizeCallback(
    MyDAWVST3Instance* instance,
    MyDAWVST3ResizeCallback callback,
    void* context
) {
    if (!instance) { return; }
    instance->resizeCallback = callback;
    instance->resizeContext  = context;
}

void MyDAWVST3RemoveEditor(MyDAWVST3Instance* instance) {
    if (!instance || !instance->editorView) {
        return;
    }
    instance->resizeCallback = nullptr;
    instance->resizeContext  = nullptr;
    instance->editorView->setFrame(nullptr);
    instance->editorView->removed();
    instance->editorView.reset();
    instance->plugFrame.reset();
}

int MyDAWVST3ProcessInterleaved(
    MyDAWVST3Instance* instance,
    const float* input,
    float* output,
    int frames,
    int channels
) {
    if (!instance || !input || !output || frames <= 0 || frames > instance->maxFrames ||
        channels != 2) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(instance->processMutex);

    for (int frame = 0; frame < frames; ++frame) {
        instance->inputLeft[frame]  = input[frame * 2];
        instance->inputRight[frame] = input[frame * 2 + 1];
    }

    instance->inputChannels[0]  = instance->inputLeft.data();
    instance->inputChannels[1]  = instance->inputRight.data();
    instance->outputChannels[0] = instance->outputLeft.data();
    instance->outputChannels[1] = instance->outputRight.data();

    Steinberg::Vst::AudioBusBuffers inputs[1]{};
    inputs[0].numChannels      = 2;
    inputs[0].channelBuffers32 = instance->inputChannels;
    Steinberg::Vst::AudioBusBuffers outputs[1]{};
    outputs[0].numChannels      = 2;
    outputs[0].channelBuffers32 = instance->outputChannels;

    Steinberg::Vst::ProcessData data{};
    data.symbolicSampleSize = Steinberg::Vst::kSample32;
    data.numSamples         = frames;
    data.numInputs          = 1;
    data.numOutputs         = 1;
    data.inputs             = inputs;
    data.outputs            = outputs;
    data.processContext     = &instance->processContext;

    if (instance->processor->process(data) != Steinberg::kResultOk) {
        return -2;
    }

    for (int frame = 0; frame < frames; ++frame) {
        output[frame * 2]     = instance->outputLeft[frame];
        output[frame * 2 + 1] = instance->outputRight[frame];
    }
    return 0;
}

int MyDAWVST3GetLatencySamples(const MyDAWVST3Instance* instance) {
    if (!instance || !instance->processor) {
        return -1;
    }
    return static_cast<int>(instance->processor->getLatencySamples());
}

int MyDAWVST3GetState(
    MyDAWVST3Instance* instance,
    void** data,
    int* size
) {
    if (!instance || !data || !size || !instance->component) {
        return -1;
    }

    Steinberg::MemoryStream stream;
    if (instance->component->getState(&stream) != Steinberg::kResultOk) {
        return -2;
    }

    const auto stateSize = stream.getSize();
    if (stateSize <= 0 || stateSize > static_cast<Steinberg::TSize>(INT32_MAX)) {
        return -3;
    }

    void* stateData = std::malloc(static_cast<size_t>(stateSize));
    if (!stateData) {
        return -4;
    }
    std::memcpy(stateData, stream.getData(), static_cast<size_t>(stateSize));
    *data = stateData;
    *size = static_cast<int>(stateSize);
    return 0;
}

int MyDAWVST3SetState(
    MyDAWVST3Instance* instance,
    const void* data,
    int size
) {
    if (!instance || !data || size <= 0 || !instance->component) {
        return -1;
    }

    Steinberg::MemoryStream stream(const_cast<void*>(data), size);
    return instance->component->setState(&stream) == Steinberg::kResultOk ? 0 : -2;
}

void MyDAWVST3FreeState(void* data) {
    std::free(data);
}

void MyDAWVST3Destroy(MyDAWVST3Instance* instance) {
    if (!instance) {
        return;
    }
    if (instance->processor) {
        instance->processor->setProcessing(false);
    }
    if (instance->component) {
        instance->component->setActive(false);
    }

    instance->editorView.reset();
    instance->plugFrame.reset();
    instance->processor  = nullptr;
    instance->controller = nullptr;
    instance->component  = nullptr;
    instance->provider.reset();
    instance->module.reset();
    instance->hostApplication.reset();
    Steinberg::Vst::PluginContextFactory::instance().setPluginContext(nullptr);
    delete instance;
}
