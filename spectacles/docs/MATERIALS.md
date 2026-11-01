# Material provenance and scientific scope

`Core/Materials.ts` evaluates `n² = 1 + Σ Bᵢ λ²/(λ² − Cᵢ)` with λ in micrometres. All C values in code are squared resonance wavelengths, or already-squared coefficients from the publication. The app restricts evaluation to 420–680 nm. Wavelengths must never be passed in metres or nanometres to the formula directly.

| Preset | Model and source | Scope |
|---|---|---|
| Crown | SCHOTT N-BK7 Sellmeier, [manufacturer data sheet](https://media.schott.com/api/public/content/41e799d0bf874807a0bb8e702fbb75b5?v=54856406) | N-BK7 specifically, not every crown glass |
| Diamond | F. Peter, *Zeitschrift für Physik* 15, 358–368 (1923), [paper](https://doi.org/10.1007/BF01328671); coefficients transcribed from the CC0 refractiveindex.info database | Isotropic cubic diamond, room temperature |
| Water | Daimon and Masumura, *Applied Optics* 46, 3811–3820 (2007), [paper](https://doi.org/10.1364/AO.46.003811) | Distilled water at 20 °C; ideal shape boundary, no vessel/fluid model |
| Sapphire | Malitson and Dodge, *JOSA* 62, 1405 (1972); Dodge, *Handbook of Laser Science and Technology*, IV, Optical Materials Part 2 (1986), p.30 | Ordinary ray at 20 °C only; does not simulate extraordinary-ray splitting |

Coefficient transcription records: [diamond](https://refractiveindex.info/?shelf=main&book=C&page=Peter), [water](https://refractiveindex.info/?shelf=main&book=H2O&page=Daimon-20.0C), [sapphire](https://refractiveindex.info/?shelf=main&book=Al2O3&page=Malitson-o). The database labels its coefficient data CC0. Reference values in tests include N-BK7's d/F/C lines; additional presets have broader sanity tolerances. No room temperature measurement is performed by the app.

The view colour response follows the existing iPhone Gaussian positive-primary approximation. Ray directions are spectral; RGB weights are illustrative and not calibrated colorimetry. A complete physical model would also transport polarization, reflected energy branches, absorption and, for sapphire, anisotropic wave propagation. The five-bounce cap discards unresolved paths explicitly.
