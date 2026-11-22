import SwiftUI

/// The property wrapper behind `@State`.
///
/// In the macOS 27 SDK the `@State` attribute resolves to a macro whose
/// compiler plugin ships only with Xcode. Naming the wrapper type keeps the
/// app buildable with just the Command Line Tools, and behaves identically.
typealias LocalState<Value> = SwiftUI.State<Value>
