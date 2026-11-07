# Nebula

Sparatutto spaziale per iPhone scritto in Swift + Metal, pensato per iPhone 17 Pro.

## Grafica
- Rendering HDR (rgba16Float) con tone mapping ACES
- 131.072 particelle simulate interamente su GPU (compute shader)
- Bloom a due livelli (Metal Performance Shaders)
- Upscaling MetalFX: scena renderizzata al 70% e ricostruita a risoluzione piena
- Nebulosa procedurale con domain warping e stelle in parallasse
- Mesh 3D low-poly illuminate, aberrazione cromatica, vignetta, grana
- 120 Hz ProMotion e feedback aptico

## Comandi
Trascina il dito per pilotare, il fuoco è automatico. L'orbe verde dà il colpo triplo per 10 secondi.

## Build
A ogni push su `main` GitHub Actions genera il progetto con XcodeGen, compila senza firma e
pubblica `Nebula.ipa` tra le Release. L'IPA va installata con Sideloadly/AltStore come le altre beta.
