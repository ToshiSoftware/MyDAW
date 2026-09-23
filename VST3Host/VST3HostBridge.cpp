#include "VST3HostBridge.h"

#include "public.sdk/source/vst/hosting/module.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"

#include <algorithm>
#include <string>

int MyDAWVST3EnumerateAudioEffects(
    const char* bundlePath,
    MyDAWVST3MetadataCallback callback,
    void* context
) {
    if (bundlePath == nullptr || callback == nullptr) {
        return -1;
    }

    std::string error;
    auto module = VST3::Hosting::Module::create(bundlePath, error);
    if (!module) {
        return -2;
    }

    int effectCount = 0;
    for (const auto& classInfo : module->getFactory().classInfos()) {
        if (classInfo.category() != kVstAudioEffectClass) {
            continue;
        }

        const bool isInstrument = std::any_of(
            classInfo.subCategories().begin(),
            classInfo.subCategories().end(),
            [](const std::string& subCategory) {
                return subCategory == "Instrument" ||
                    subCategory.rfind("Instrument|", 0) == 0;
            }
        );
        if (isInstrument) {
            continue;
        }

        const std::string uid = classInfo.ID().toString();
        callback(
            uid.c_str(),
            classInfo.name().c_str(),
            classInfo.vendor().c_str(),
            classInfo.version().c_str(),
            context
        );
        ++effectCount;
    }

    return effectCount;
}
