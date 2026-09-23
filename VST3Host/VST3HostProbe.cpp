#include "public.sdk/source/vst/hosting/module.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/vsttypes.h"
#include "VST3PluginInstance.h"

#include <algorithm>
#include <iostream>
#include <string>
#include <vector>

namespace {

void printUsage(const char* executable) {
    std::cerr << "Usage: " << executable << " /path/to/Plugin.vst3\n";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        printUsage(argv[0]);
        return 2;
    }

    const std::string modulePath = argv[1];
    std::string error;
    auto module = VST3::Hosting::Module::create(modulePath, error);
    if (!module) {
        std::cerr << "Could not load VST3 module: " << error << "\n";
        return 1;
    }

    std::cout << "Module: " << module->getName() << "\n";
    std::cout << "Path: " << module->getPath() << "\n";

    const auto classInfos = module->getFactory().classInfos();
    bool foundAudioEffect = false;
    for (const auto& classInfo : classInfos) {
        if (classInfo.category() != kVstAudioEffectClass) {
            continue;
        }

        foundAudioEffect = true;
        std::cout << "AudioEffect UID: " << classInfo.ID().toString() << "\n";
        std::cout << "Name: " << classInfo.name() << "\n";
        std::cout << "Vendor: " << classInfo.vendor() << "\n";
        std::cout << "Version: " << classInfo.version() << "\n";
    }

    if (!foundAudioEffect) {
        std::cerr << "No VST3 audio effect class found.\n";
        return 1;
    }

    const auto& firstEffect = *std::find_if(
        classInfos.begin(),
        classInfos.end(),
        [](const auto& classInfo) {
            return classInfo.category() == kVstAudioEffectClass;
        }
    );
    auto instance = MyDAWVST3Create(
        modulePath.c_str(),
        firstEffect.ID().toString().c_str(),
        44100.0,
        512
    );
    if (!instance) {
        std::cerr << "Could not instantiate the first VST3 audio effect.\n";
        return 1;
    }

    std::vector<float> input(512 * 2, 0.0f);
    std::vector<float> output(512 * 2, 0.0f);
    input[0] = 0.25f;
    const int processResult = MyDAWVST3ProcessInterleaved(
        instance,
        input.data(),
        output.data(),
        512,
        2
    );
    std::cout << "Process result: " << processResult << "\n";
    std::cout << "Latency samples: " << MyDAWVST3GetLatencySamples(instance) << "\n";
    void* stateData = nullptr;
    int stateSize = 0;
    const int captureResult = MyDAWVST3GetState(instance, &stateData, &stateSize);
    std::cout << "State capture result: " << captureResult << "\n";
    std::cout << "State bytes: " << stateSize << "\n";
    const int restoreResult = captureResult == 0
        ? MyDAWVST3SetState(instance, stateData, stateSize)
        : -1;
    std::cout << "State restore result: " << restoreResult << "\n";
    MyDAWVST3FreeState(stateData);
    MyDAWVST3Destroy(instance);
    if (processResult != 0 || captureResult != 0 || restoreResult != 0) {
        return 1;
    }

    return 0;
}
