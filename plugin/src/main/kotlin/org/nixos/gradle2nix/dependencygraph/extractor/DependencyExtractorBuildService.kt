package org.nixos.gradle2nix.dependencygraph.extractor

import org.gradle.api.provider.Property
import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters

abstract class DependencyExtractorBuildService :
    DependencyExtractor(),
    BuildService<DependencyExtractorBuildService.Params>
{
    internal interface Params : BuildServiceParameters {
        val rendererClassName: Property<String>
    }

    override fun getRendererClassName(): String {
        return parameters.rendererClassName.get()
    }
}
