// Explicit compatibility methods for MoonBit warning 0079
// (implicit_impl_as_method). They keep derived trait methods callable
// with dot syntax during the deprecation period without adding them to
// the public interface.

///|
#deprecated("Use `Debug::to_repr` or `debug_inspect` instead", skip_current_package=true)
#doc(hidden)
pub extend RepoError with Debug::{to_repr}

///|
#deprecated("Use `==` or `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend RepoError with Eq::{equal, not_equal}

///|
#deprecated("Format the error with string interpolation instead", skip_current_package=true)
#doc(hidden)
pub extend RepoError with Show::{to_string, output}

///|
#deprecated("Use `Debug::to_repr` or `debug_inspect` instead", skip_current_package=true)
#doc(hidden)
pub extend PackageFile with Debug::{to_repr}

///|
#deprecated("Use `==` or `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend PackageFile with Eq::{equal, not_equal}
