use mornye_extensions::ffmpeg::{CommandRegistry, CommandResult, RegistryClosed};
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum FfmpegError {
    #[error("FFmpeg command registry closed")]
    Closed,
}

impl From<RegistryClosed> for FfmpegError {
    fn from(_: RegistryClosed) -> Self {
        Self::Closed
    }
}

/// All handles returned by one environment refer to its single command queue.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct FfmpegCommands {
    pub(crate) inner: Arc<CommandRegistry>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl FfmpegCommands {
    pub fn wait_pending(&self, timeout_ms: i64) -> Result<String, FfmpegError> {
        self.inner.wait_pending_json(timeout_ms).map_err(Into::into)
    }

    pub fn get_command(&self, command_id: String) -> Result<String, FfmpegError> {
        Ok(self
            .inner
            .get(&command_id)?
            .map_or_else(String::new, |command| {
                serde_json::to_string(&command).expect("FFmpeg command JSON")
            }))
    }

    pub fn complete(
        &self,
        command_id: String,
        success: bool,
        output: String,
        error: String,
    ) -> Result<bool, FfmpegError> {
        self.inner
            .complete(
                &command_id,
                CommandResult {
                    success,
                    output,
                    error,
                },
            )
            .map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}
