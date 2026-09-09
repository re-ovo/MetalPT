# Algorithm references and historical data attribution

The current renderer uses linear RGB, fixed-IOR glass (1.5), and an approximate RGB gold reflectance (1.0, 0.71, 0.29). It does not load spectral tables. The CIE and Au datasets and Sellmeier implementation were removed during the RGB refactor. The attribution below is retained for historical versions; statements about sampling and bundled datasets describe those versions only.

# Spectral data and algorithm references

The renderer loads the following bundled data; it never downloads assets at runtime.

- `CIE_xyz_1931_2deg.csv` and its unmodified metadata: CIE 2019, *CIE 1931 colour-matching functions, 2 degree observer*, DOI [10.25039/CIE.DS.xvudnb9b](https://doi.org/10.25039/CIE.DS.xvudnb9b), original source CIE 018:2019 Table 6. [Dataset](https://cie.co.at/datatable/cie-1931-colour-matching-functions-2-degree-observer). **CC BY-SA 4.0**, https://creativecommons.org/licenses/by-sa/4.0/. The original 1 nm samples are retained. The renderer linearly interpolates them and uses 106.856895 as the visible Y integral normalization. Any redistribution of these data or adaptations must preserve attribution and their license.
- `Au_Johnson.yml`: P. B. Johnson and R. W. Christy, *Optical constants of the noble metals*, Physical Review B 6, 4370–4379 (1972), https://doi.org/10.1103/PhysRevB.6.4370. Data from the [refractiveindex.info database](https://github.com/polyanskiy/refractiveindex.info-database/blob/master/database/data/main/Au/nk/Johnson.yml), **CC0 1.0** (full text in `CC0-1.0.txt`). Wavelength is converted from micrometres to nm and n/k are linearly resampled to 1 nm at scene creation.
- BK7 Sellmeier coefficients are numerical facts from SCHOTT N-BK7 optical glass data: B = (1.03961212, 0.231792344, 1.01046945), C = (0.00600069867, 0.0200179144, 103.560653) in µm². [SCHOTT optical glass catalog](https://refractiveindex.info/download/data/2017/schott_2017-01-20.pdf). No vendor document or explanatory text is bundled. Only the refractive index is modelled; absorption is omitted.
- Diffuse pigment curves are original bounded Gaussian basis mixtures; their coefficients are not a colorimetrically exact RGB-to-spectrum conversion. Procedural textures modulate these spectra with scalar values. Light sources have equal-energy spectra.

Independent implementations informed by [PBRT wavefront rendering](https://www.pbr-book.org/4ed/Wavefront_Rendering_on_GPUs/Path_Tracer_Implementation), [sampled wavelengths](https://www.pbr-book.org/4ed/Radiometry%2C_Spectra%2C_and_Color/Representing_Spectral_Distributions), and [dielectric BSDFs](https://pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF). No PBRT code or RGB spectral lookup tables are copied.

Display uses an ACES-inspired rational tone curve (K. Narkowicz, [ACES Filmic Tone Mapping Curve](https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/)) followed by the sRGB transfer function. It is not a full ACES color-management pipeline.
