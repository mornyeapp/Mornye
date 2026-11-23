//! Android-owned USB permission and a bounded, mixer-free USB audio transport.
//! No resampling or gain processing occurs at this boundary: a song whose
//! rate the DAC refuses passes through [`UsbResampler`] before it gets here.

#[cfg(any(test, target_os = "android"))]
mod descriptors;
#[cfg(any(test, target_os = "android"))]
mod framing;
mod resample;
#[cfg(target_os = "android")]
#[allow(unsafe_code)] // libusb ownership is confined to this worker module.
mod transport;
#[cfg(any(test, target_os = "android"))]
mod volume;

use std::sync::{Arc, Mutex};

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum UsbAudioError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<String> for UsbAudioError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

#[derive(uniffi::Record, Clone)]
pub struct UsbOutputFormat {
    pub sample_rate: u32,
    pub channels: u8,
    pub bits: u8,
    pub subslot: u8,
    /// pcm, dop, dsd_be or dsd_le. Native DSD is selected by exact device ID.
    pub encoding: String,
}

#[derive(uniffi::Record, Clone, Default)]
pub struct UsbHardwareVolume {
    pub available: bool,
    pub min_db: f64,
    pub max_db: f64,
    pub current_db: f64,
    /// Quietest channel before startup attenuation; restoring a previous UI
    /// setting must respect a DAC volume knob that was lowered externally.
    pub restore_limit_db: f64,
}

#[derive(uniffi::Object)]
pub struct UsbDirectOutput {
    #[cfg(target_os = "android")]
    output: transport::Output,
}

#[uniffi::export]
impl UsbDirectOutput {
    /// The caller retains its UsbDeviceConnection until shutdown() completes.
    #[uniffi::constructor]
    pub fn open(
        fd: i32,
        descriptors: Vec<u8>,
        sample_rate: u32,
        channels: u8,
        bits: u8,
        dsd: bool,
        allow_dop: bool,
    ) -> Result<Arc<Self>, UsbAudioError> {
        #[cfg(target_os = "android")]
        {
            let output = transport::Output::open(
                fd,
                descriptors,
                sample_rate,
                channels,
                bits,
                dsd,
                allow_dop,
            )?;
            Ok(Arc::new(Self { output }))
        }
        #[cfg(not(target_os = "android"))]
        {
            let _ = (fd, descriptors, sample_rate, channels, bits, dsd, allow_dop);
            Err("Direct USB audio requires Android".to_string().into())
        }
    }

    pub fn format(&self) -> UsbOutputFormat {
        #[cfg(target_os = "android")]
        return self.output.format.clone();
        #[cfg(not(target_os = "android"))]
        unreachable!("Android-only constructor")
    }

    /// Nonblocking; returns zero when the bounded queue is full.
    pub fn write(&self, data: Vec<u8>) -> Result<u32, UsbAudioError> {
        #[cfg(target_os = "android")]
        return self.output.write(data).map_err(Into::into);
        #[cfg(not(target_os = "android"))]
        {
            let _ = data;
            unreachable!("Android-only constructor")
        }
    }

    /// Advisory, frame-aligned capacity before copying a buffer across FFI.
    pub fn available_bytes(&self) -> Result<u32, UsbAudioError> {
        #[cfg(target_os = "android")]
        return self.output.available_bytes().map_err(Into::into);
        #[cfg(not(target_os = "android"))]
        unreachable!("Android-only constructor")
    }

    pub fn start(&self) -> Result<(), UsbAudioError> {
        #[cfg(target_os = "android")]
        return self.output.start().map_err(Into::into);
        #[cfg(not(target_os = "android"))]
        unreachable!("Android-only constructor")
    }

    /// Cancels in-flight transfers, clears buffered audio and resets position.
    pub fn flush(&self) -> Result<(), UsbAudioError> {
        #[cfg(target_os = "android")]
        return self.output.flush().map_err(Into::into);
        #[cfg(not(target_os = "android"))]
        unreachable!("Android-only constructor")
    }

    /// Counts completed USB frames, excluding inserted silence.
    pub fn frames(&self) -> Result<u64, UsbAudioError> {
        #[cfg(target_os = "android")]
        return self.output.frames().map_err(Into::into);
        #[cfg(not(target_os = "android"))]
        unreachable!("Android-only constructor")
    }

    pub fn shutdown(&self) {
        #[cfg(target_os = "android")]
        self.output.close();
    }

    pub fn volume(&self) -> UsbHardwareVolume {
        #[cfg(target_os = "android")]
        return self.output.volume();
        #[cfg(not(target_os = "android"))]
        unreachable!("Android-only constructor")
    }

    pub fn set_volume(&self, db: f64) -> Result<UsbHardwareVolume, UsbAudioError> {
        #[cfg(target_os = "android")]
        return self.output.set_volume(db).map_err(Into::into);
        #[cfg(not(target_os = "android"))]
        {
            let _ = db;
            unreachable!("Android-only constructor")
        }
    }
}

/// Converts PCM to a rate the DAC accepts when it refuses the song's own.
/// Samples are little-endian and left-justified in `subslot` bytes, `bits`
/// of them valid, exactly as [`UsbDirectOutput::write`] takes them.
#[derive(uniffi::Object)]
pub struct UsbResampler {
    resampler: Mutex<resample::Resampler>,
}

#[uniffi::export]
impl UsbResampler {
    #[uniffi::constructor]
    pub fn create(
        source_rate: u32,
        output_rate: u32,
        channels: u8,
        subslot: u8,
        bits: u8,
        high_pass_dither: bool,
    ) -> Result<Arc<Self>, UsbAudioError> {
        let resampler = resample::Resampler::new(
            source_rate,
            output_rate,
            channels,
            subslot,
            bits,
            high_pass_dither,
        )?;
        Ok(Arc::new(Self {
            resampler: Mutex::new(resampler),
        }))
    }

    /// Takes whole frames; returns the output frames they complete.
    pub fn process(&self, data: Vec<u8>) -> Result<Vec<u8>, UsbAudioError> {
        self.lock().process(&data).map_err(Into::into)
    }

    /// The frames still inside the filter once the source has ended.
    pub fn finish(&self) -> Vec<u8> {
        self.lock().finish()
    }

    /// Forgets the audio heard so far, as after a seek.
    pub fn reset(&self) {
        self.lock().reset();
    }
}

impl UsbResampler {
    fn lock(&self) -> std::sync::MutexGuard<'_, resample::Resampler> {
        self.resampler.lock().expect("USB resampler")
    }
}
