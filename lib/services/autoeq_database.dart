import 'dart:math' as math;
import 'package:mornye/models/autoeq_models.dart';

/// Database and parser for AutoEq / Wavelet headphone compensation curves.
class AutoEqDatabase {
  static const List<double> standardFrequencies = [
    31.25,
    62.5,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0,
  ];

  static final List<AutoEqProfile> profiles = [
    // ----------------- APPLE -----------------
    const AutoEqProfile(
      id: 'apple_airpods_pro_2',
      brand: 'Apple',
      model: 'AirPods Pro 2',
      type: 'In-Ear',
      preamp: -3.5,
      gains: [3.2, 2.4, 0.8, -0.6, 0.0, 0.5, 1.8, -1.2, 0.4, 1.5],
    ),
    const AutoEqProfile(
      id: 'apple_airpods_pro',
      brand: 'Apple',
      model: 'AirPods Pro',
      type: 'In-Ear',
      preamp: -4.0,
      gains: [4.1, 2.8, 1.2, -0.5, 0.2, 1.0, 2.4, -0.8, -1.0, 2.0],
    ),
    const AutoEqProfile(
      id: 'apple_airpods_max',
      brand: 'Apple',
      model: 'AirPods Max',
      type: 'Over-Ear',
      preamp: -4.8,
      gains: [4.5, 3.2, 1.0, -1.5, -0.8, 0.5, 2.1, 1.5, -2.5, 0.8],
    ),
    const AutoEqProfile(
      id: 'apple_airpods_3',
      brand: 'Apple',
      model: 'AirPods 3',
      type: 'Earbuds',
      preamp: -5.2,
      gains: [5.5, 3.8, 1.5, -1.0, 0.2, 1.4, 3.0, -1.5, -2.0, 1.2],
    ),
    const AutoEqProfile(
      id: 'apple_airpods_2',
      brand: 'Apple',
      model: 'AirPods 2',
      type: 'Earbuds',
      preamp: -6.0,
      gains: [6.5, 4.5, 2.0, -0.5, 0.0, 1.2, 2.8, -2.0, -3.0, 0.5],
    ),
    const AutoEqProfile(
      id: 'apple_earpods',
      brand: 'Apple',
      model: 'EarPods',
      type: 'Earbuds',
      preamp: -5.5,
      gains: [5.8, 4.0, 1.8, -0.8, 0.2, 1.5, 2.5, -1.8, -2.5, 1.0],
    ),

    // ----------------- SONY -----------------
    const AutoEqProfile(
      id: 'sony_wh_1000xm4',
      brand: 'Sony',
      model: 'WH-1000XM4',
      type: 'Over-Ear',
      preamp: -5.0,
      gains: [1.5, -1.8, -4.2, -2.5, 0.5, 1.8, 3.5, 4.2, 1.0, 2.5],
    ),
    const AutoEqProfile(
      id: 'sony_wh_1000xm5',
      brand: 'Sony',
      model: 'WH-1000XM5',
      type: 'Over-Ear',
      preamp: -4.2,
      gains: [2.0, -0.5, -2.8, -1.5, 0.2, 1.5, 2.8, 3.5, 0.5, 2.0],
    ),
    const AutoEqProfile(
      id: 'sony_wh_1000xm3',
      brand: 'Sony',
      model: 'WH-1000XM3',
      type: 'Over-Ear',
      preamp: -5.5,
      gains: [1.0, -2.5, -5.0, -3.0, 0.8, 2.0, 4.0, 4.5, 0.8, 2.2],
    ),
    const AutoEqProfile(
      id: 'sony_wf_1000xm4',
      brand: 'Sony',
      model: 'WF-1000XM4',
      type: 'In-Ear',
      preamp: -4.5,
      gains: [2.5, 1.0, -1.5, -1.0, 0.5, 1.8, 3.2, 2.5, 0.2, 1.8],
    ),
    const AutoEqProfile(
      id: 'sony_wf_1000xm5',
      brand: 'Sony',
      model: 'WF-1000XM5',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [2.8, 1.5, -0.8, -0.5, 0.2, 1.2, 2.5, 2.0, 0.5, 1.5],
    ),
    const AutoEqProfile(
      id: 'sony_linkbuds_s',
      brand: 'Sony',
      model: 'LinkBuds S',
      type: 'In-Ear',
      preamp: -3.5,
      gains: [2.4, 1.2, -1.0, -0.4, 0.6, 1.5, 2.8, 1.8, 0.0, 1.6],
    ),
    const AutoEqProfile(
      id: 'sony_wh_ch720n',
      brand: 'Sony',
      model: 'WH-CH720N',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [1.8, -1.2, -3.5, -2.0, 0.8, 2.0, 3.8, 3.2, 0.5, 2.4],
    ),
    const AutoEqProfile(
      id: 'sony_mdr_7506',
      brand: 'Sony',
      model: 'MDR-7506',
      type: 'Over-Ear',
      preamp: -5.5,
      gains: [5.2, 3.5, 1.0, -0.5, 0.2, -0.5, -1.2, -4.5, -2.0, 1.5],
    ),

    // ----------------- SENNHEISER -----------------
    const AutoEqProfile(
      id: 'sennheiser_hd600',
      brand: 'Sennheiser',
      model: 'HD 600',
      type: 'Over-Ear',
      preamp: -6.5,
      gains: [6.8, 5.2, 2.5, 0.5, -0.2, 0.0, 0.8, 1.2, 0.5, 2.0],
    ),
    const AutoEqProfile(
      id: 'sennheiser_hd650',
      brand: 'Sennheiser',
      model: 'HD 650',
      type: 'Over-Ear',
      preamp: -6.2,
      gains: [6.5, 4.8, 2.0, 0.2, -0.5, 0.0, 1.0, 1.8, 1.2, 2.5],
    ),
    const AutoEqProfile(
      id: 'sennheiser_hd560s',
      brand: 'Sennheiser',
      model: 'HD 560S',
      type: 'Over-Ear',
      preamp: -4.8,
      gains: [4.5, 3.0, 1.2, -0.2, 0.0, -0.5, -0.8, -1.5, 0.5, 1.8],
    ),
    const AutoEqProfile(
      id: 'sennheiser_hd660s',
      brand: 'Sennheiser',
      model: 'HD 660S',
      type: 'Over-Ear',
      preamp: -5.8,
      gains: [5.8, 4.2, 1.8, 0.0, -0.4, 0.2, 1.4, 2.2, 1.0, 2.8],
    ),
    const AutoEqProfile(
      id: 'sennheiser_momentum_4',
      brand: 'Sennheiser',
      model: 'Momentum 4',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [0.5, -2.0, -3.8, -1.8, 0.5, 1.8, 3.2, 2.8, 0.8, 2.2],
    ),
    const AutoEqProfile(
      id: 'sennheiser_momentum_tw3',
      brand: 'Sennheiser',
      model: 'Momentum True Wireless 3',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.2, -0.8, -2.2, -1.0, 0.4, 1.5, 2.8, 2.0, 0.5, 1.8],
    ),
    const AutoEqProfile(
      id: 'sennheiser_hd280pro',
      brand: 'Sennheiser',
      model: 'HD 280 Pro',
      type: 'Over-Ear',
      preamp: -5.0,
      gains: [3.8, 2.0, -0.5, -1.2, 0.2, 1.0, 2.4, -2.8, -1.0, 1.5],
    ),
    const AutoEqProfile(
      id: 'sennheiser_ie200',
      brand: 'Sennheiser',
      model: 'IE 200',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [3.8, 2.5, 0.5, -0.5, 0.2, 1.0, 2.2, -1.5, -0.8, 2.0],
    ),
    const AutoEqProfile(
      id: 'sennheiser_hd800s',
      brand: 'Sennheiser',
      model: 'HD 800 S',
      type: 'Over-Ear',
      preamp: -6.5,
      gains: [6.8, 4.2, 1.0, -0.4, 0.0, 0.2, 1.0, -3.5, -2.8, 2.5],
    ),
    const AutoEqProfile(
      id: 'sennheiser_hd490_pro',
      brand: 'Sennheiser',
      model: 'HD 490 Pro',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [4.2, 2.5, 0.5, -0.4, 0.0, 0.4, 1.2, -1.8, -0.5, 1.8],
    ),

    // ----------------- SAMSUNG / AKG -----------------
    const AutoEqProfile(
      id: 'samsung_galaxy_buds2_pro',
      brand: 'Samsung',
      model: 'Galaxy Buds 2 Pro',
      type: 'In-Ear',
      preamp: -2.5,
      gains: [1.8, 1.0, 0.2, -0.4, 0.0, 0.4, 1.2, -0.8, 0.2, 1.2],
    ),
    const AutoEqProfile(
      id: 'samsung_galaxy_buds_pro',
      brand: 'Samsung',
      model: 'Galaxy Buds Pro',
      type: 'In-Ear',
      preamp: -3.0,
      gains: [2.2, 1.4, 0.4, -0.5, 0.2, 0.8, 1.8, -1.2, 0.0, 1.4],
    ),
    const AutoEqProfile(
      id: 'samsung_galaxy_buds2',
      brand: 'Samsung',
      model: 'Galaxy Buds 2',
      type: 'In-Ear',
      preamp: -3.2,
      gains: [2.5, 1.6, 0.5, -0.6, 0.2, 1.0, 2.0, -1.0, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'samsung_galaxy_buds_fe',
      brand: 'Samsung',
      model: 'Galaxy Buds FE',
      type: 'In-Ear',
      preamp: -3.0,
      gains: [2.0, 1.2, 0.2, -0.4, 0.0, 0.6, 1.5, -0.5, 0.4, 1.4],
    ),
    const AutoEqProfile(
      id: 'akg_k371',
      brand: 'AKG',
      model: 'K371',
      type: 'Over-Ear',
      preamp: -2.8,
      gains: [1.5, 0.8, -0.2, -0.5, 0.2, 0.5, 1.4, -0.4, 0.2, 1.8],
    ),
    const AutoEqProfile(
      id: 'akg_k240',
      brand: 'AKG',
      model: 'K240 Studio',
      type: 'Over-Ear',
      preamp: -6.5,
      gains: [7.2, 5.5, 2.8, 0.5, -0.5, 0.0, 1.2, 2.0, 1.0, 2.2],
    ),
    const AutoEqProfile(
      id: 'akg_k702',
      brand: 'AKG',
      model: 'K702',
      type: 'Over-Ear',
      preamp: -6.8,
      gains: [7.5, 5.8, 3.0, 0.8, -0.2, -0.5, 0.5, -1.2, 0.8, 2.0],
    ),

    // ----------------- BOSE -----------------
    const AutoEqProfile(
      id: 'bose_qc35_ii',
      brand: 'Bose',
      model: 'QuietComfort 35 II',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [4.2, 2.8, 1.0, -0.8, -0.2, 0.8, 2.2, 1.0, -1.5, 1.8],
    ),
    const AutoEqProfile(
      id: 'bose_qc45',
      brand: 'Bose',
      model: 'QuietComfort 45',
      type: 'Over-Ear',
      preamp: -5.2,
      gains: [4.8, 3.2, 1.2, -0.5, 0.0, 0.5, 1.8, -3.2, -1.8, 1.5],
    ),
    const AutoEqProfile(
      id: 'bose_qc_ultra',
      brand: 'Bose',
      model: 'QuietComfort Ultra',
      type: 'Over-Ear',
      preamp: -4.0,
      gains: [3.5, 2.0, 0.5, -1.0, -0.4, 0.6, 2.0, 0.5, -1.0, 2.0],
    ),
    const AutoEqProfile(
      id: 'bose_qc_earbuds_2',
      brand: 'Bose',
      model: 'QuietComfort Earbuds II',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [1.0, -1.2, -2.8, -1.4, 0.5, 1.6, 3.0, 2.2, 0.4, 1.8],
    ),
    const AutoEqProfile(
      id: 'bose_700',
      brand: 'Bose',
      model: 'Noise Cancelling 700',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [4.5, 3.0, 1.0, -0.6, 0.0, 0.8, 2.4, 0.5, -1.2, 2.2],
    ),

    // ----------------- AUDIO-TECHNICA -----------------
    const AutoEqProfile(
      id: 'ath_m50x',
      brand: 'Audio-Technica',
      model: 'ATH-M50x',
      type: 'Over-Ear',
      preamp: -4.8,
      gains: [2.5, 0.5, -2.2, -1.8, 0.5, 1.5, 2.8, -2.5, -1.8, 2.4],
    ),
    const AutoEqProfile(
      id: 'ath_m40x',
      brand: 'Audio-Technica',
      model: 'ATH-M40x',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [3.0, 1.2, -1.5, -1.0, 0.4, 1.2, 2.2, -1.8, -1.2, 2.0],
    ),
    const AutoEqProfile(
      id: 'ath_r70x',
      brand: 'Audio-Technica',
      model: 'ATH-R70x',
      type: 'Over-Ear',
      preamp: -5.8,
      gains: [5.8, 4.2, 1.8, 0.2, -0.4, 0.2, 1.5, 1.2, 0.5, 2.0],
    ),

    // ----------------- BEYERDYNAMIC -----------------
    const AutoEqProfile(
      id: 'beyer_dt770_80',
      brand: 'Beyerdynamic',
      model: 'DT 770 Pro (80 Ohm)',
      type: 'Over-Ear',
      preamp: -6.0,
      gains: [3.0, 1.2, -1.8, -1.5, 0.8, 2.0, 3.2, -4.5, -3.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'beyer_dt770_250',
      brand: 'Beyerdynamic',
      model: 'DT 770 Pro (250 Ohm)',
      type: 'Over-Ear',
      preamp: -6.2,
      gains: [3.2, 1.5, -1.5, -1.2, 0.6, 1.8, 3.0, -5.0, -3.5, 1.8],
    ),
    const AutoEqProfile(
      id: 'beyer_dt990_250',
      brand: 'Beyerdynamic',
      model: 'DT 990 Pro (250 Ohm)',
      type: 'Over-Ear',
      preamp: -6.8,
      gains: [4.5, 2.8, 0.5, -1.0, 0.4, 1.5, 2.5, -5.8, -4.0, 1.2],
    ),
    const AutoEqProfile(
      id: 'beyer_dt1990_pro',
      brand: 'Beyerdynamic',
      model: 'DT 1990 Pro',
      type: 'Over-Ear',
      preamp: -5.8,
      gains: [4.8, 3.2, 1.0, -0.5, 0.2, 1.0, 2.0, -5.2, -3.0, 1.8],
    ),
    const AutoEqProfile(
      id: 'beyer_dt880_pro',
      brand: 'Beyerdynamic',
      model: 'DT 880 Pro',
      type: 'Over-Ear',
      preamp: -5.5,
      gains: [5.0, 3.5, 1.2, -0.2, 0.0, 0.8, 1.8, -3.8, -2.0, 1.5],
    ),

    // ----------------- MOONDROP -----------------
    const AutoEqProfile(
      id: 'moondrop_aria',
      brand: 'Moondrop',
      model: 'Aria',
      type: 'In-Ear',
      preamp: -3.2,
      gains: [2.5, 1.8, 0.5, -0.5, 0.2, 0.8, 1.8, -1.2, 0.4, 1.8],
    ),
    const AutoEqProfile(
      id: 'moondrop_chu_2',
      brand: 'Moondrop',
      model: 'Chu II',
      type: 'In-Ear',
      preamp: -3.0,
      gains: [2.0, 1.2, 0.2, -0.4, 0.0, 0.6, 1.5, -0.8, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'moondrop_blessing_2',
      brand: 'Moondrop',
      model: 'Blessing 2',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [4.2, 3.0, 1.0, -0.2, 0.0, 0.4, 1.2, -0.5, 0.5, 2.0],
    ),
    const AutoEqProfile(
      id: 'moondrop_blessing_2_dusk',
      brand: 'Moondrop',
      model: 'Blessing 2 Dusk',
      type: 'In-Ear',
      preamp: -2.8,
      gains: [2.2, 1.5, 0.5, -0.2, 0.0, 0.4, 1.2, -0.4, 0.4, 1.8],
    ),
    const AutoEqProfile(
      id: 'moondrop_kato',
      brand: 'Moondrop',
      model: 'Kato',
      type: 'In-Ear',
      preamp: -3.0,
      gains: [2.8, 1.8, 0.5, -0.4, 0.2, 0.8, 1.6, -0.8, 0.4, 1.8],
    ),
    const AutoEqProfile(
      id: 'moondrop_variations',
      brand: 'Moondrop',
      model: 'Variations',
      type: 'In-Ear',
      preamp: -2.5,
      gains: [1.5, 0.8, 0.0, -0.2, 0.0, 0.5, 1.2, -0.5, 0.5, 1.5],
    ),
    const AutoEqProfile(
      id: 'moondrop_space_travel',
      brand: 'Moondrop',
      model: 'Space Travel',
      type: 'In-Ear',
      preamp: -3.2,
      gains: [1.8, 1.0, 0.2, -0.4, 0.2, 0.5, 1.8, -1.0, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'moondrop_aria_2',
      brand: 'Moondrop',
      model: 'Aria 2',
      type: 'In-Ear',
      preamp: -3.0,
      gains: [2.0, 1.2, 0.2, -0.4, 0.2, 0.6, 2.0, -1.2, 0.4, 1.6],
    ),

    // ----------------- ANKER SOUNDCORE -----------------
    const AutoEqProfile(
      id: 'soundcore_life_q30',
      brand: 'Soundcore',
      model: 'Life Q30',
      type: 'Over-Ear',
      preamp: -5.5,
      gains: [0.0, -3.5, -6.2, -3.8, 0.8, 2.2, 4.0, 3.5, 0.8, 2.5],
    ),
    const AutoEqProfile(
      id: 'soundcore_space_q45',
      brand: 'Soundcore',
      model: 'Space Q45',
      type: 'Over-Ear',
      preamp: -4.8,
      gains: [1.2, -1.8, -4.5, -2.5, 0.5, 1.8, 3.5, 3.0, 0.5, 2.0],
    ),
    const AutoEqProfile(
      id: 'soundcore_liberty_4_nc',
      brand: 'Soundcore',
      model: 'Liberty 4 NC',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [1.0, -1.5, -3.2, -1.8, 0.6, 1.8, 3.2, 2.0, 0.2, 1.8],
    ),

    // ----------------- GOOGLE -----------------
    const AutoEqProfile(
      id: 'google_pixel_buds_pro',
      brand: 'Google',
      model: 'Pixel Buds Pro',
      type: 'In-Ear',
      preamp: -3.5,
      gains: [1.5, -0.5, -2.0, -1.0, 0.4, 1.2, 2.5, 1.8, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'google_pixel_buds_a',
      brand: 'Google',
      model: 'Pixel Buds A-Series',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [3.2, 2.0, 0.5, -0.4, 0.2, 0.8, 2.0, -1.0, 0.4, 1.8],
    ),

    // ----------------- BEATS -----------------
    const AutoEqProfile(
      id: 'beats_studio_pro',
      brand: 'Beats',
      model: 'Studio Pro',
      type: 'Over-Ear',
      preamp: -4.2,
      gains: [2.5, 0.8, -1.5, -1.2, 0.4, 1.5, 2.8, 1.8, 0.0, 1.8],
    ),
    const AutoEqProfile(
      id: 'beats_fit_pro',
      brand: 'Beats',
      model: 'Fit Pro',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [2.8, 1.5, -0.5, -0.8, 0.2, 1.2, 2.5, 1.2, 0.0, 1.5],
    ),
    const AutoEqProfile(
      id: 'beats_studio_3',
      brand: 'Beats',
      model: 'Studio 3',
      type: 'Over-Ear',
      preamp: -5.0,
      gains: [1.0, -2.0, -4.5, -2.5, 0.8, 2.0, 3.5, 3.0, 0.5, 2.0],
    ),

    // ----------------- NOTHING -----------------
    const AutoEqProfile(
      id: 'nothing_ear_2',
      brand: 'Nothing',
      model: 'Ear (2)',
      type: 'In-Ear',
      preamp: -3.5,
      gains: [2.5, 1.2, -0.8, -0.6, 0.2, 1.2, 2.4, -0.8, 0.2, 1.8],
    ),
    const AutoEqProfile(
      id: 'nothing_ear_a',
      brand: 'Nothing',
      model: 'Ear (a)',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.8, 0.5, -1.5, -0.8, 0.4, 1.4, 2.8, -0.5, 0.4, 1.8],
    ),

    // ----------------- KZ -----------------
    const AutoEqProfile(
      id: 'kz_zsn_pro',
      brand: 'KZ',
      model: 'ZSN Pro',
      type: 'In-Ear',
      preamp: -5.5,
      gains: [1.0, -1.8, -3.8, -2.0, 0.8, 2.0, 1.5, -5.2, -4.0, 1.2],
    ),
    const AutoEqProfile(
      id: 'kz_zs10_pro',
      brand: 'KZ',
      model: 'ZS10 Pro',
      type: 'In-Ear',
      preamp: -5.0,
      gains: [1.5, -1.2, -3.0, -1.8, 0.6, 1.8, 2.0, -4.5, -3.2, 1.5],
    ),

    // ----------------- JBL -----------------
    const AutoEqProfile(
      id: 'jbl_tune_710bt',
      brand: 'JBL',
      model: 'Tune 710BT',
      type: 'Over-Ear',
      preamp: -3.5,
      gains: [1.8, 0.8, -0.5, -0.8, 0.2, 0.8, 2.2, 1.0, 0.0, 1.8],
    ),
    const AutoEqProfile(
      id: 'jbl_tune_510bt',
      brand: 'JBL',
      model: 'Tune 510BT',
      type: 'On-Ear',
      preamp: -5.0,
      gains: [1.2, -2.0, -4.5, -2.2, 0.8, 2.0, 3.2, 2.5, 0.5, 2.0],
    ),

    // ----------------- HIFIMAN -----------------
    const AutoEqProfile(
      id: 'hifiman_sundara',
      brand: 'Hifiman',
      model: 'Sundara',
      type: 'Over-Ear',
      preamp: -5.5,
      gains: [5.8, 4.0, 1.5, 0.0, -0.2, 0.0, 0.5, 0.8, 0.2, 1.8],
    ),
    const AutoEqProfile(
      id: 'hifiman_edition_xs',
      brand: 'Hifiman',
      model: 'Edition XS',
      type: 'Over-Ear',
      preamp: -5.0,
      gains: [5.2, 3.5, 1.2, -0.2, 0.0, 0.2, 0.8, -1.2, 0.5, 2.0],
    ),

    // ----------------- MARSHALL -----------------
    const AutoEqProfile(
      id: 'marshall_major_4',
      brand: 'Marshall',
      model: 'Major IV',
      type: 'On-Ear',
      preamp: -5.2,
      gains: [1.5, -1.8, -4.8, -2.8, 0.6, 1.8, 3.5, 2.8, 0.5, 2.2],
    ),

    // ----------------- SHURE -----------------
    const AutoEqProfile(
      id: 'shure_se215',
      brand: 'Shure',
      model: 'SE215',
      type: 'In-Ear',
      preamp: -5.5,
      gains: [1.0, -2.2, -4.5, -2.5, 0.8, 2.2, 4.2, 3.8, 0.8, 2.5],
    ),

    // ----------------- KIWI EARS -----------------
    const AutoEqProfile(
      id: 'kiwi_ears_belle',
      brand: 'Kiwi Ears',
      model: 'Belle',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [1.8, 1.2, 0.5, -0.2, 0.4, 0.8, 2.8, -1.5, -0.6, 1.2],
    ),
    const AutoEqProfile(
      id: 'kiwi_ears_cadenza',
      brand: 'Kiwi Ears',
      model: 'Cadenza',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.5, 0.8, 0.2, -0.4, 0.2, 0.6, 2.4, -1.8, 0.4, 1.8],
    ),
    const AutoEqProfile(
      id: 'kiwi_ears_quintet',
      brand: 'Kiwi Ears',
      model: 'Quintet',
      type: 'In-Ear',
      preamp: -4.0,
      gains: [2.0, 1.0, 0.0, -0.6, 0.2, 0.5, 2.2, -2.2, -1.0, 2.0],
    ),
    const AutoEqProfile(
      id: 'kiwi_ears_orchestra_lite',
      brand: 'Kiwi Ears',
      model: 'Orchestra Lite',
      type: 'In-Ear',
      preamp: -3.5,
      gains: [2.8, 1.8, 0.6, -0.2, 0.0, 0.4, 1.5, -1.0, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'kiwi_ears_melody',
      brand: 'Kiwi Ears',
      model: 'Melody',
      type: 'In-Ear',
      preamp: -4.5,
      gains: [1.2, 0.4, -0.8, -1.2, 0.4, 1.0, 2.8, -2.0, -1.5, 1.4],
    ),

    // ----------------- CMF BY NOTHING -----------------
    const AutoEqProfile(
      id: 'cmf_buds_pro_2',
      brand: 'CMF',
      model: 'Buds Pro 2',
      type: 'In-Ear',
      preamp: -5.0,
      gains: [-1.5, -3.2, -2.0, 0.2, 0.8, 1.5, 3.2, 1.2, -0.5, 2.2],
    ),
    const AutoEqProfile(
      id: 'cmf_buds_pro',
      brand: 'CMF',
      model: 'Buds Pro',
      type: 'In-Ear',
      preamp: -4.8,
      gains: [-1.2, -2.8, -1.8, 0.0, 0.6, 1.2, 3.0, 0.8, -0.8, 1.8],
    ),
    const AutoEqProfile(
      id: 'cmf_buds',
      brand: 'CMF',
      model: 'Buds',
      type: 'In-Ear',
      preamp: -4.5,
      gains: [-0.8, -2.2, -1.5, 0.2, 0.5, 1.0, 2.8, 1.0, -0.4, 1.5],
    ),

    // ----------------- 7HZ -----------------
    const AutoEqProfile(
      id: '7hz_zero_2',
      brand: '7Hz',
      model: 'Zero 2',
      type: 'In-Ear',
      preamp: -3.6,
      gains: [1.2, 0.6, 0.0, -0.4, 0.2, 0.5, 2.0, -1.4, 0.2, 1.6],
    ),
    const AutoEqProfile(
      id: '7hz_zero',
      brand: '7Hz',
      model: 'Salnotes Zero',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [2.5, 1.5, 0.4, -0.2, 0.0, 0.4, 1.8, -1.6, 0.5, 1.8],
    ),
    const AutoEqProfile(
      id: '7hz_timeless',
      brand: '7Hz',
      model: 'Timeless',
      type: 'In-Ear',
      preamp: -4.0,
      gains: [1.0, 0.2, -0.6, -0.8, 0.2, 0.8, 2.2, -2.5, -1.2, 2.2],
    ),
    const AutoEqProfile(
      id: '7hz_sonus',
      brand: '7Hz',
      model: 'Sonus',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.6, 0.8, 0.2, -0.5, 0.0, 0.6, 2.5, -1.8, -0.2, 1.5],
    ),

    // ----------------- TRUTHEAR -----------------
    const AutoEqProfile(
      id: 'truthear_hexa',
      brand: 'Truthear',
      model: 'Hexa',
      type: 'In-Ear',
      preamp: -3.4,
      gains: [1.8, 1.0, 0.2, -0.2, 0.0, 0.4, 1.5, -1.0, 0.6, 1.4],
    ),
    const AutoEqProfile(
      id: 'truthear_zero_red',
      brand: 'Truthear',
      model: 'Zero:RED',
      type: 'In-Ear',
      preamp: -3.5,
      gains: [1.5, 0.8, 0.0, -0.4, 0.2, 0.6, 2.0, -1.2, 0.4, 1.6],
    ),
    const AutoEqProfile(
      id: 'truthear_zero',
      brand: 'Truthear',
      model: 'Zero (Blue)',
      type: 'In-Ear',
      preamp: -4.0,
      gains: [0.8, 0.0, -0.8, -0.6, 0.2, 0.8, 2.4, -1.8, 0.2, 1.8],
    ),
    const AutoEqProfile(
      id: 'truthear_nova',
      brand: 'Truthear',
      model: 'Nova',
      type: 'In-Ear',
      preamp: -3.6,
      gains: [1.0, 0.4, -0.2, -0.5, 0.2, 0.5, 1.8, -1.5, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'truthear_gate',
      brand: 'Truthear',
      model: 'Gate',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.6, 0.9, 0.2, -0.3, 0.1, 0.5, 2.2, -1.6, 0.4, 1.4],
    ),

    // ----------------- TANGZU -----------------
    const AutoEqProfile(
      id: 'tangzu_waner',
      brand: 'Tangzu',
      model: "Wan'er S.G",
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.4, 0.8, 0.2, -0.4, 0.2, 0.6, 2.2, -1.6, 0.2, 1.5],
    ),
    const AutoEqProfile(
      id: 'tangzu_fudu',
      brand: 'Tangzu',
      model: 'Fudu Verse 1',
      type: 'In-Ear',
      preamp: -4.0,
      gains: [1.0, 0.2, -0.4, -0.6, 0.2, 0.8, 2.5, -1.8, 0.0, 1.8],
    ),

    // ----------------- NOTHING -----------------
    const AutoEqProfile(
      id: 'nothing_ear_2024',
      brand: 'Nothing',
      model: 'Ear (2024)',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [1.2, 0.4, -0.5, -0.8, 0.2, 0.8, 2.6, -1.4, -0.5, 1.8],
    ),
    const AutoEqProfile(
      id: 'nothing_ear_a',
      brand: 'Nothing',
      model: 'Ear (a)',
      type: 'In-Ear',
      preamp: -4.5,
      gains: [0.5, -0.6, -1.2, -0.8, 0.4, 1.0, 2.8, -1.2, -0.8, 1.6],
    ),
    const AutoEqProfile(
      id: 'nothing_ear_2',
      brand: 'Nothing',
      model: 'Ear (2)',
      type: 'In-Ear',
      preamp: -4.6,
      gains: [1.0, 0.2, -0.8, -1.0, 0.2, 1.0, 3.0, -1.8, -1.0, 2.0],
    ),

    // ----------------- FIIO / JADEAUDIO -----------------
    const AutoEqProfile(
      id: 'fiio_fh3',
      brand: 'Fiio',
      model: 'FH3',
      type: 'In-Ear',
      preamp: -4.2,
      gains: [0.8, -0.2, -1.2, -0.8, 0.4, 1.0, 2.6, -1.8, -0.6, 1.8],
    ),
    const AutoEqProfile(
      id: 'fiio_fd3',
      brand: 'Fiio',
      model: 'FD3',
      type: 'In-Ear',
      preamp: -4.0,
      gains: [1.2, 0.4, -0.6, -0.6, 0.2, 0.8, 2.4, -2.0, -0.8, 2.0],
    ),
    const AutoEqProfile(
      id: 'fiio_jh5',
      brand: 'Fiio',
      model: 'JH5',
      type: 'In-Ear',
      preamp: -3.8,
      gains: [1.5, 0.6, 0.0, -0.4, 0.2, 0.6, 2.2, -1.6, 0.0, 1.6],
    ),
    const AutoEqProfile(
      id: 'fiio_jt1',
      brand: 'Fiio',
      model: 'JT1',
      type: 'Over-Ear',
      preamp: -4.5,
      gains: [0.5, -0.8, -2.0, -1.2, 0.4, 1.2, 2.8, 0.8, -1.2, 1.5],
    ),

    // ----------------- FOCAL -----------------
    const AutoEqProfile(
      id: 'focal_bathys',
      brand: 'Focal',
      model: 'Bathys',
      type: 'Over-Ear',
      preamp: -4.0,
      gains: [1.8, 0.8, -0.4, -0.8, 0.0, 0.5, 1.8, -1.0, 0.2, 1.6],
    ),
    const AutoEqProfile(
      id: 'focal_clear',
      brand: 'Focal',
      model: 'Clear',
      type: 'Over-Ear',
      preamp: -4.8,
      gains: [4.8, 2.8, 0.5, -0.5, 0.0, 0.2, 1.2, -1.5, 0.5, 2.2],
    ),

    // ----------------- MEZE -----------------
    const AutoEqProfile(
      id: 'meze_109_pro',
      brand: 'Meze',
      model: '109 Pro',
      type: 'Over-Ear',
      preamp: -4.2,
      gains: [3.8, 2.0, 0.2, -0.5, 0.0, 0.4, 1.6, -2.2, -1.2, 1.8],
    ),
    const AutoEqProfile(
      id: 'meze_99_classics',
      brand: 'Meze',
      model: '99 Classics',
      type: 'Over-Ear',
      preamp: -6.0,
      gains: [-1.2, -4.0, -5.5, -3.2, 0.8, 2.0, 3.8, 2.4, 0.5, 2.0],
    ),

    // ----------------- AUDEZE -----------------
    const AutoEqProfile(
      id: 'audeze_lcd_x',
      brand: 'Audeze',
      model: 'LCD-X',
      type: 'Over-Ear',
      preamp: -5.2,
      gains: [2.5, 1.2, 0.2, 0.0, 0.4, 1.0, 3.5, 2.2, -0.8, 1.5],
    ),
    const AutoEqProfile(
      id: 'audeze_maxwell',
      brand: 'Audeze',
      model: 'Maxwell',
      type: 'Over-Ear',
      preamp: -3.5,
      gains: [1.8, 0.8, 0.0, -0.2, 0.0, 0.2, 1.2, -0.8, 0.4, 1.4],
    ),
  ];

  static List<String> get availableBrands {
    final brands = profiles.map((p) => p.brand).toSet().toList();
    brands.sort();
    return brands;
  }

  static List<AutoEqProfile> search(String query, {String? brand}) {
    final q = query.trim().toLowerCase();
    return profiles.where((p) {
      if (brand != null && brand.isNotEmpty && p.brand != brand) {
        return false;
      }
      if (q.isEmpty) return true;
      return p.displayName.toLowerCase().contains(q) ||
          p.brand.toLowerCase().contains(q) ||
          p.model.toLowerCase().contains(q) ||
          p.type.toLowerCase().contains(q);
    }).toList();
  }

  /// Parses a Wavelet GraphicEQ line, such as:
  /// `GraphicEQ: 20 0.0; 25 1.2; 31.5 2.5; ...`
  /// or multi-point frequency-gain text and interpolates at Mornye's 10 bands.
  static AutoEqProfile? parseWaveletGraphicEq(String name, String content) {
    var text = content.trim();
    if (text.startsWith('GraphicEQ:')) {
      text = text.substring('GraphicEQ:'.length).trim();
    }

    final pairs = <(double, double)>[];
    final entries = text.split(RegExp(r'[;\n]'));
    for (final entry in entries) {
      final parts = entry
          .trim()
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length >= 2) {
        final freq = double.tryParse(parts[0]);
        final gain = double.tryParse(parts[1]);
        if (freq != null && gain != null && freq > 0) {
          pairs.add((freq, gain));
        }
      }
    }

    if (pairs.length < 3) return null;
    pairs.sort((a, b) => a.$1.compareTo(b.$1));

    // Interpolate gains for standard 10 frequencies
    final gains = <double>[];
    for (final targetHz in standardFrequencies) {
      gains.add(_interpolateLogFreq(pairs, targetHz));
    }

    // Determine safe headroom preamp:
    final maxGain = gains.reduce(math.max);
    final preamp = maxGain > 0 ? -(maxGain + 0.5) : 0.0;

    final trimmedName = name.trim().replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');

    return AutoEqProfile(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      brand: 'Custom',
      model: trimmedName.isEmpty ? 'Wavelet AutoEq' : trimmedName,
      type: 'Imported',
      preamp: (preamp * 10).round() / 10,
      gains: gains.map((g) => (g * 10).round() / 10).toList(),
    );
  }

  static double _interpolateLogFreq(List<(double, double)> pairs, double hz) {
    if (hz <= pairs.first.$1) return pairs.first.$2;
    if (hz >= pairs.last.$1) return pairs.last.$2;

    for (var i = 1; i < pairs.length; i++) {
      final prev = pairs[i - 1];
      final curr = pairs[i];
      if (hz <= curr.$1) {
        final logPrev = math.log(prev.$1);
        final logCurr = math.log(curr.$1);
        final logTarget = math.log(hz);
        final fraction = (logTarget - logPrev) / (logCurr - logPrev);
        return prev.$2 + (curr.$2 - prev.$2) * fraction;
      }
    }
    return pairs.last.$2;
  }
}
