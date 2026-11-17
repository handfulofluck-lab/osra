### Android child — RTL layout opt-in (#709)
- The application now opts into Android's right-to-left layout mirroring.
- The picture-in-picture and protection-screen cover keeps physical window coordinates anchored to the physical left, so enabling RTL cannot move the cover away from the window it obscures.
- The quick-settings SOS tile already reads its English label from `sos_tile_label`; its Arabic override is reserved for the Arabic Language Bureau.
