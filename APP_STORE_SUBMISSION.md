# DrainMap — App Store submission checklist

## Positioning
**Name:** DrainMap  
**Subtitle:** Pendenza e deflusso LiDAR  
**Primary category:** Utilities  
**Secondary category:** Productivity

## Short description
DrainMap usa il sensore LiDAR dell’iPhone per leggere rapidamente pendenza, dislivello e direzione di deflusso di una superficie. La mappa locale evidenzia zone alte e basse, individua il punto più basso e mostra una stima del percorso naturale dell’acqua.

## Suggested keywords
lidar,pendenza,drenaggio,deflusso,superficie,livella,pavimento,terrazza,rilievo

## Review notes
DrainMap requires an iPhone equipped with LiDAR for live measurements.

Suggested reviewer flow:
1. Launch the app and complete the short onboarding.
2. Grant camera permission.
3. Point the device at a floor or other visible surface from roughly 0.4–3 m.
4. Wait for the quality indicator to become Good/Excellent.
5. Verify live slope %, degrees, downhill direction, surface map, low point and estimated flow path.
6. Save a measurement and open it from the Measurements tab.
7. Use Share from the detail screen to export a text summary.

The camera and LiDAR frames are processed on-device. The app does not require an account, does not use advertising or analytics SDKs and does not transmit scan data to a server.

## App Privacy answers
- Data collected: **None**
- Tracking: **No**
- Data linked to user: **None**
- Camera/LiDAR: processed locally for core functionality
- UserDefaults: used only for app-local preferences and saved measurements

The privacy manifest declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`.

## Export compliance
`ITSAppUsesNonExemptEncryption = false` because DrainMap does not implement non-exempt encryption.

## Before TestFlight / submission
- [ ] Add final AppIcon asset (1024 × 1024 source and generated iPhone sizes)
- [ ] Run on a physical LiDAR iPhone and validate slope/heatmap orientation
- [ ] Check camera-denied and non-LiDAR states
- [ ] Capture App Store screenshots on a supported iPhone
- [ ] Publish support and privacy URLs
- [ ] Complete age rating questionnaire
- [ ] Confirm App Privacy = Data Not Collected
- [ ] Upload signed build to TestFlight
- [ ] Complete one external/internal TestFlight pass before App Review
