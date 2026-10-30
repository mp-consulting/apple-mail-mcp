import Foundation

#if !canImport(ObjectiveC)
/// Linux has no autorelease pools (no Objective-C runtime): the body just runs.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }
#endif
