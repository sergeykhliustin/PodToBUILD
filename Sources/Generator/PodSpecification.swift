//
//  PodSpecification.swift
//  PodToBUILD
//
//  Created by Sergey Khliustin on 25.08.2022.
//

import Foundation
import PodToBUILD

struct PodSpecification {
    let name: String
    let subspecs: [String]
    let podspec: String

    static func resolve(with podConfigs: [PodConfig]) -> [PodSpecification] {
        let (podspecPaths, subspecsByPodName) =
        podConfigs.reduce(([String: String](), [String: [String]]())) { partialResult, podConfig in
            var podspecPaths = partialResult.0
            var subspecsByPodName = partialResult.1

            let components = podConfig.name.components(separatedBy: "/")
            guard let podName = components.first else {
                return partialResult
            }

            podspecPaths[podName] = podConfig.podspec

            if components.count == 2, let subspecName = components.last {
                var subspecs = subspecsByPodName[podName] ?? []
                subspecs.append(subspecName)
                subspecsByPodName[podName] = subspecs
            }
            return (podspecPaths, subspecsByPodName)
        }
        return podspecPaths.map({
            PodSpecification(name: $0.key, subspecs: subspecsByPodName[$0.key] ?? [], podspec: $0.value)
        })
    }

    func toBuildOptions() -> BuildOptions {
        return BasicBuildOptions(podName: name, subspecs: subspecs, podspecPath: podspec)
    }
}
