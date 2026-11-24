# CineRig

CineRig is a filming add-on for World of Warcraft Retail. Walk or fly your character while the add-on pans, tilts or changes camera distance. Record a movement once and replay it from a different starting frame.

## Install with WowUp

1. Select your **Retail** installation in WowUp.
2. Open **Get Addons → Install from URL**.
3. Paste `https://github.com/CesarGrado/CineRig` and click **Import**. Review **CineRig** and click **Install**. WowUp can then check GitHub for future releases.
4. Enable CineRig at character selection. Type `/cine` in game.

If WowUp shows **Addon Installation Failed** when importing the repository, you can install 1.5.2 directly. Paste the following address into **Install from URL** and click **Import**, then **Install**. WowUp treats a direct ZIP as a one-time install.

```text
https://github.com/CesarGrado/CineRig/releases/download/v1.5.2/CineRig-1.5.2.zip
```

For manual installation, extract the attached CineRig ZIP from Releases into `_retail_/Interface/AddOns`. The TOC should be at `AddOns/CineRig/CineRig.toc`. The current release targets Retail 12.1.5, interface 120105.

## Film a shot

- In **Options → Keybindings → CineRig**, assign **Stop**, **Restore**, **Toggle walking session** and the Operator or Nudge controls you want to use. Disable DynamicCam on the filming character and reload before using CineRig-driven moves.
- Use `/cine presets` to choose a movement. Try **Look up and return** on a first-person walk or **Widening arc** for a third-person reveal.
- To reuse a move, enter `/cine record Bridge pass`, perform your pan, tilt and zoom with CineRig controls, then press **Start or finish movement recording**. Frame the next shot and use `/cine replay Bridge pass`.
- For a clean frame, use the walking-session binding. With mouse-look off, free-cursor hiding is an opt-in experiment under `/cine cursor`. Check cursor visibility in your recorded footage.

You control character travel and video recording. CineRig saves the camera commands and pauses. Terrain, starting distance and your route affect each replay. [Controls and recovery](CineRig/QUICKSTART.txt)
