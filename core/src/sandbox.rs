use std::path::{Path, PathBuf};

#[cfg(target_os = "macos")]
mod platform {
    use std::ptr;

    use base64::Engine;
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use core_foundation::url::{
        CFURL, CFURLCreateByResolvingBookmarkData, CFURLStopAccessingSecurityScopedResource,
        kCFURLBookmarkResolutionWithoutUIMask,
    };

    use super::{BookmarkError, ScopedRoot};

    pub fn resolve_transfer_bookmark(encoded: &str) -> Result<ScopedRoot, BookmarkError> {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| BookmarkError::InvalidBase64)?;
        if bytes.is_empty() {
            return Err(BookmarkError::Empty);
        }

        let data = CFData::from_buffer(&bytes);
        let mut stale = 0_u8;
        let mut error = ptr::null_mut();

        let raw_url = unsafe {
            CFURLCreateByResolvingBookmarkData(
                ptr::null(),
                data.as_concrete_TypeRef(),
                kCFURLBookmarkResolutionWithoutUIMask,
                ptr::null(),
                ptr::null(),
                &mut stale,
                &mut error,
            )
        };

        if raw_url.is_null() {
            return Err(BookmarkError::ResolveFailed);
        }

        let url = unsafe { CFURL::wrap_under_create_rule(raw_url) };
        let path = url.to_path().ok_or(BookmarkError::NotFileURL)?;

        Ok(ScopedRoot {
            path,
            security_scoped_url: Some(url),
        })
    }

    impl Drop for ScopedRoot {
        fn drop(&mut self) {
            if let Some(url) = self.security_scoped_url.take() {
                unsafe {
                    CFURLStopAccessingSecurityScopedResource(url.as_concrete_TypeRef());
                }
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::{BookmarkError, ScopedRoot};

    pub fn resolve_transfer_bookmark(_: &str) -> Result<ScopedRoot, BookmarkError> {
        Err(BookmarkError::UnsupportedPlatform)
    }
}

#[derive(Debug)]
pub struct ScopedRoot {
    path: PathBuf,
    #[cfg(target_os = "macos")]
    security_scoped_url: Option<core_foundation::url::CFURL>,
}

impl ScopedRoot {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BookmarkError {
    InvalidBase64,
    Empty,
    ResolveFailed,
    NotFileURL,
    UnsupportedPlatform,
}

pub use platform::resolve_transfer_bookmark;
