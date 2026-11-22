# ADR-0001: Swift core shared everywhere, native UI shell per OS

Date: 2026-11-22 · Status: proposed

## Context
Owner chose native Swift. Targets: iOS, macOS, Android, Windows. Swift 6.3 (Mar 2026) shipped the
first official Swift SDK for Android with swift-java/JNI interop; SwiftUI does not run on Android
or Windows. Swift is officially supported on Windows; WinUI bindings (swift-winrt) are community-grade.

## Decision
One SwiftPM package `ZennoxCore` (library DB, metadata parsing, Drive REST client, duplicate
detection, queue/shuffle logic, offline cache policy) compiled for all four OSes. Native UI shells:
SwiftUI for iOS + macOS (one multiplatform target); Kotlin + Jetpack Compose + Media3 on Android,
calling ZennoxCore through swift-java; Windows shell decided by spike S9 (Swift + swift-winrt vs
C#/WinUI 3 over a C ABI exported from ZennoxCore).

## Alternatives considered
- SwiftUI everywhere — impossible today on Android/Windows.
- Skip (SwiftUI→Compose) — adds a transpiler dependency; no Windows; revisit if Android shell cost hurts.
- Flutter/KMP — rejected by owner preference for Swift.

## Consequences
Apple ships first; Android and Windows each need their own UI and audio/session layer (~40% extra
UI work per OS). ZennoxCore must import no Apple frameworks (`#if canImport` behind adapters);
CI builds core for all four triples on every merge.
