// Explicit compatibility methods for MoonBit warning 0079
// (implicit_impl_as_method). They keep derived trait methods callable
// with dot syntax during the deprecation period without adding them to
// the public interface.

///|
#deprecated("Use `Debug::to_repr` or `debug_inspect` instead", skip_current_package=true)
#doc(hidden)
pub extend TarError with Debug::{to_repr}

///|
#deprecated("Use `==` or `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend TarError with Eq::{equal, not_equal}

///|
#deprecated("Use `Debug::to_repr` or `debug_inspect` instead", skip_current_package=true)
#doc(hidden)
pub extend EntryKind with Debug::{to_repr}

///|
#deprecated("Use `==` or `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend EntryKind with Eq::{equal, not_equal}

///|
#deprecated("Use `Debug::to_repr` or `debug_inspect` instead", skip_current_package=true)
#doc(hidden)
pub extend Entry with Debug::{to_repr}

///|
#deprecated("Use `==` or `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend Entry with Eq::{equal, not_equal}

///|
#deprecated("Format the error with string interpolation instead", skip_current_package=true)
#doc(hidden)
pub extend TarError with Show::{to_string, output}

///|
#deprecated("Use `Debug::to_repr` or `debug_inspect` instead", skip_current_package=true)
#doc(hidden)
pub extend LongNames with Debug::{to_repr}

///|
#deprecated("Use `==` or `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend LongNames with Eq::{equal, not_equal}
