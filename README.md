# DrainMap

DrainMap is a native iPhone LiDAR app for quickly checking surface slope and drainage direction.

## MVP goals
- Real LiDAR depth acquisition with ARKit
- Live slope in % and degrees
- Downhill direction indicator
- Measurement quality and working distance
- Save measurements locally on device
- Clean, futuristic HUD-style interface
- No account, no cloud and no tracking in the first release

## Road to 1.0
1. Compile-valid native MVP and physical LiDAR test
2. Local elevation heatmap and lowest-point detection
3. Drain point selection and simple water-flow simulation
4. App icon, onboarding, screenshots and App Store metadata
5. TestFlight validation and submission

## Requirements
- Xcode 16+
- iOS 17+
- iPhone with LiDAR for live measurements

## Build
Open `DrainMap.xcodeproj`, select a signing team, choose a physical LiDAR iPhone and run.

## Current status
First native MVP scaffold. The project is intentionally separate from ONE.
