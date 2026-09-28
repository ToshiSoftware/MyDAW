#include "VST3PluginInstance.h"

#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
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
#include <utility>
#include <vector>

// Forward declaration
struct MyDAWVST3Instance;

// Receives parameter edits from the plug-in's controller (its GUI) so they
// can be delivered to the processor through ProcessData on the next block.
// Plug-ins with split controller/processor rely on this; without it GUI
// changes never reach the DSP.
class MyDAWVST3ComponentHandler : public Steinberg::Vst::IComponentHandler {
public:
    MyDAWVST3ComponentHandler() { pending.reserve(256); }

    Steinberg::tresult PLUGIN_API beginEdit(Steinberg::Vst::ParamID) override {
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API performEdit(
        Steinberg::Vst::ParamID id,
        Steinberg::Vst::ParamValue value
    ) override {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& entry : pending) {
            if (entry.first == id) {
                entry.second = value;
                return Steinberg::kResultOk;
            }
        }
        pending.emplace_back(id, value);
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API endEdit(Steinberg::Vst::ParamID) override {
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API restartComponent(Steinberg::int32) override {
        return Steinberg::kResultOk;
    }

    Steinberg::tresult PLUGIN_API queryInterface(
        const Steinberg::TUID iid,
        void** obj
    ) override {
        if (!obj) {
            return Steinberg::kInvalidArgument;
        }
        if (Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::Vst::IComponentHandler::iid) ||
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

    // Render thread: never blocks; if the UI thread holds the lock the
    // edits simply arrive one block later.
    void drainInto(Steinberg::Vst::ParameterChanges& changes) {
        std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        if (!lock.owns_lock()) {
            return;
        }
        for (const auto& entry : pending) {
            Steinberg::int32 queueIndex = 0;
            if (auto* queue = changes.addParameterData(entry.first, queueIndex)) {
                Steinberg::int32 pointIndex = 0;
                queue->addPoint(0, entry.second, pointIndex);
            }
        }
        pending.clear();
    }

private:
    std::mutex mutex;
    std::vector<std::pair<Steinberg::Vst::ParamID, Steinberg::Vst::ParamValue>> pending;
};

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
    MyDAWVST3ComponentHandler componentHandler;
    Steinberg::Vst::ParameterChanges inputParameterChanges{64};
    Steinberg::Vst::ParameterChanges outputParameterChanges{64};
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
    int processFailureLogCount = 0;

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
    if (instance->controller) {
        instance->controller->setComponentHandler(&instance->componentHandler);
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
        fprintf(stderr, "[MyDAWVST3] activateBus failed for %s\n", selectedClass.name().c_str());
        return nullptr;
    }

    Steinberg::Vst::SpeakerArrangement inputArrangement  = Steinberg::Vst::SpeakerArr::kStereo;
    Steinberg::Vst::SpeakerArrangement outputArrangement = Steinberg::Vst::SpeakerArr::kStereo;
    auto busArrangementResult = instance->processor->setBusArrangements(&inputArrangement, 1, &outputArrangement, 1);
    if (busArrangementResult != Steinberg::kResultOk) {
        fprintf(
            stderr,
            "[MyDAWVST3] setBusArrangements returned %d (not kResultOk) for %s; plugin may reject stereo I/O\n",
            static_cast<int>(busArrangementResult),
            selectedClass.name().c_str()
        );
    }

    Steinberg::Vst::ProcessSetup setup {
        Steinberg::Vst::kRealtime,
        Steinberg::Vst::kSample32,
        maxFrames,
        sampleRate
    };
    auto setupResult = instance->processor->setupProcessing(setup);
    auto activeResult = instance->component->setActive(true);
    auto processingResult = instance->processor->setProcessing(true);
    if (setupResult != Steinberg::kResultOk ||
        activeResult != Steinberg::kResultOk ||
        processingResult != Steinberg::kResultOk) {
        fprintf(
            stderr,
            "[MyDAWVST3] init failed for %s: setupProcessing=%d setActive=%d setProcessing=%d\n",
            selectedClass.name().c_str(),
            static_cast<int>(setupResult),
            static_cast<int>(activeResult),
            static_cast<int>(processingResult)
        );
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

static void attachParameterChanges(MyDAWVST3Instance* instance, Steinberg::Vst::ProcessData& data) {
    instance->inputParameterChanges.clearQueue();
    instance->componentHandler.drainInto(instance->inputParameterChanges);
    instance->outputParameterChanges.clearQueue();
    data.inputParameterChanges  = &instance->inputParameterChanges;
    data.outputParameterChanges = &instance->outputParameterChanges;
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
        if (instance && instance->processFailureLogCount < 5) {
            ++instance->processFailureLogCount;
            fprintf(
                stderr,
                "[MyDAWVST3] ProcessInterleaved rejected: frames=%d maxFrames=%d channels=%d hasInput=%d hasOutput=%d\n",
                frames,
                instance ? instance->maxFrames : -1,
                channels,
                input != nullptr,
                output != nullptr
            );
        }
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
    attachParameterChanges(instance, data);

    auto processResult = instance->processor->process(data);
    if (processResult != Steinberg::kResultOk) {
        if (instance->processFailureLogCount < 5) {
            ++instance->processFailureLogCount;
            fprintf(
                stderr,
                "[MyDAWVST3] process() returned %d (not kResultOk), frames=%d\n",
                static_cast<int>(processResult),
                frames
            );
        }
        return -2;
    }

    for (int frame = 0; frame < frames; ++frame) {
        output[frame * 2]     = instance->outputLeft[frame];
        output[frame * 2 + 1] = instance->outputRight[frame];
    }
    return 0;
}

int MyDAWVST3ProcessStereo(
    MyDAWVST3Instance* instance,
    const float* inputLeft,
    const float* inputRight,
    float* outputLeft,
    float* outputRight,
    int frames
) {
    if (!instance || !inputLeft || !inputRight || !outputLeft || !outputRight ||
        frames <= 0 || frames > instance->maxFrames) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(instance->processMutex);

    float* inputChannels[2] = {const_cast<float*>(inputLeft), const_cast<float*>(inputRight)};
    float* outputChannels[2] = {outputLeft, outputRight};

    Steinberg::Vst::AudioBusBuffers inputs[1]{};
    inputs[0].numChannels      = 2;
    inputs[0].channelBuffers32 = inputChannels;
    Steinberg::Vst::AudioBusBuffers outputs[1]{};
    outputs[0].numChannels      = 2;
    outputs[0].channelBuffers32 = outputChannels;

    Steinberg::Vst::ProcessData data{};
    data.symbolicSampleSize = Steinberg::Vst::kSample32;
    data.numSamples         = frames;
    data.numInputs          = 1;
    data.numOutputs         = 1;
    data.inputs             = inputs;
    data.outputs            = outputs;
    data.processContext     = &instance->processContext;
    attachParameterChanges(instance, data);

    const auto result = instance->processor->process(data);
    instance->processContext.projectTimeSamples += frames;
    return result == Steinberg::kResultOk ? 0 : -2;
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
    if (instance->component->setState(&stream) != Steinberg::kResultOk) {
        return -2;
    }
    if (instance->controller) {
        stream.seek(0, Steinberg::IBStream::kIBSeekSet, nullptr);
        instance->controller->setComponentState(&stream);
    }
    return 0;
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
    if (instance->controller) {
        instance->controller->setComponentHandler(nullptr);
    }
    instance->processor  = nullptr;
    instance->controller = nullptr;
    instance->component  = nullptr;
    instance->provider.reset();
    instance->module.reset();
    instance->hostApplication.reset();
    Steinberg::Vst::PluginContextFactory::instance().setPluginContext(nullptr);
    delete instance;
}
