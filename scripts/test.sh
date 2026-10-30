#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests build/module-cache
python3 Tests/PublicFilesTests.py
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache \
  Sources/Core.swift Tests/CoreTests.swift -o build/tests/core-tests
build/tests/core-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache \
  Sources/Core.swift Sources/VoiceCommands.swift Tests/VoiceCommandTests.swift -o build/tests/voice-tests
build/tests/voice-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache \
  Sources/FaceRating.swift Tests/FaceRatingTests.swift -o build/tests/face-tests
build/tests/face-tests
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.2 -module-cache-path build/module-cache \
  Sources/FaceReferences.swift Tests/FaceReferenceTests.swift -o build/tests/reference-tests
build/tests/reference-tests
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.2 -module-cache-path build/module-cache \
  Sources/Core.swift Sources/Submission.swift Sources/Desktop.swift Tests/DesktopTests.swift -o build/tests/desktop-tests
build/tests/desktop-tests
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.2 -module-cache-path build/module-cache \
  Sources/Core.swift Sources/Submission.swift Sources/Desktop.swift Sources/FaceRating.swift Sources/FaceMesh.swift Sources/FaceAnalysis.swift Sources/FaceReferences.swift Sources/FaceDebug.swift \
  Tests/ScreenWatchTests.swift -o build/tests/screen-watch-tests
build/tests/screen-watch-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache \
  Sources/Core.swift Sources/Submission.swift Tests/SubmissionTests.swift -o build/tests/submission-tests
build/tests/submission-tests
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.2 -module-cache-path build/module-cache \
  Sources/Core.swift Sources/Submission.swift Sources/Desktop.swift Sources/FaceRating.swift Sources/FaceMesh.swift Sources/FaceAnalysis.swift \
  Tests/FaceVisionTests.swift -o build/tests/face-vision-tests
build/tests/face-vision-tests
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.2 -module-cache-path build/module-cache \
  Sources/Core.swift Sources/Submission.swift Sources/Desktop.swift Sources/FaceRating.swift Sources/FaceMesh.swift Sources/FaceAnalysis.swift Sources/FaceReferences.swift \
  Tests/FaceReferenceVisionTests.swift -o build/tests/reference-vision-tests
build/tests/reference-vision-tests
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.2 -module-cache-path build/module-cache \
  Sources/Core.swift Sources/Submission.swift Sources/Desktop.swift Sources/FaceRating.swift Sources/FaceMesh.swift Sources/FaceAnalysis.swift \
  Tests/FaceMeshTests.swift -o build/tests/mesh-tests
build/tests/mesh-tests --native
