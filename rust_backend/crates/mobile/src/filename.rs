#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
#[cfg_attr(feature = "uniffi", uniffi(flat_error))]
pub enum FilenameError {
    #[error("{message}")]
    Invalid { message: String },
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
pub fn build_filename(template: String, metadata_json: String) -> Result<String, FilenameError> {
    mornye_core::filename::build_filename_json(&template, &metadata_json)
        .map_err(|message| FilenameError::Invalid { message })
}
