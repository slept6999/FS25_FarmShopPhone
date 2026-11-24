# Farm Shop Phone for FS25

Version **0.2.6.2**. The mod opens a phone overlay, automatically finds the trading points of the loaded map and lets you enter the standard FS25 shop interface. It adds no buildings, NPCs or assortment and does not change prices or the economy. Store Deliveries was used only as a reference for the approach; its scripts and assets are not loaded.

## Features

- Key **O** opens/closes the phone.
- Only shops with a genuinely available purchase interface are discovered (`placeableSystem.placeables`, `mapHotspots` of type `SHOP`, `ShopTrigger`); `storeSpawnPlaces` is not used as a source.
- De-duplication is by object reference, not by name/coordinates.
- Points that accept bulk goods (`spec_sellingStation`), animal dealers (`spec_animalDealer`) and owned workshops (`ownWorkshop`) are excluded.
- Two fulfillment methods: **pickup** and **delivery to the player** with a 2.5% surcharge (max. 5000). A phone-call fee of 10 applies when a seller is selected and their shop is opened via the **Call** button (charged only when the store opens successfully; if opening fails, nothing is charged).
- Delivery spot validation: terrain sampled at 9 bounding-box points, height difference, slope, water, collisions, clearance from the player/vehicle.
- Pallets are placed in a line (no overlap), using their real dimensions.
- Purchase is confirmed by actual object creation (hooks on `VehicleLoadingData`/`PlaceableLoadingData`), not by catalog close and not by a finance event.
- Order state machine; partial delivery is never reported as success; the delivery fee only counts recognized purchase types.
- Centralized spawn-place restoration: idempotent, never overwrites other mods' changes.
- Single-player only; multiplayer is disabled in `modDesc.xml`.

## Controls

| Key | Action (phone open) |
|---------|---------------------------------|
| **O** | Open / close the phone |
| **↑ / ↓** | Select a supplier |
| **Enter** | Activate the focused element |
| **Tab** / **Shift+Tab** | Next / previous interactive element |
| **A** or **←** | Pickup |
| **D** or **→** | Delivery to the player |
| **Backspace** | Close the phone (back) |
| **Esc** | Close the phone |
| Mouse wheel | Scroll the list |
| LMB | Select shop/method, press buttons |

When the phone opens, focus is on the first list row. After selecting a shop, focus moves to the fulfillment method, then to the call button. The button action fires on left-button release if the cursor is still over it.

> While the phone is open, player and camera input is locked. While the FS25 shop catalog is open, the phone keys are not intercepted.

## Installation

1. Download the ready `.zip` from **Releases** and place it as a whole into your `mods` folder (do not unpack).
   - Windows: `Documents\My Games\FarmingSimulator2025\mods`
2. Enable **Farm Shop Phone** in the savegame mod list.
3. Press **O** in game.
4. Make sure `log.txt` has no XML/Lua loading errors.

## Ordering flow

1. Open the phone with **O**.
2. Select a supplier (**↑ / ↓** or click).
3. Choose fulfillment: pickup or delivery.
4. Press **Enter** — the original catalog of the selected point opens.
5. Buy goods in the regular in-game catalog.
6. Pick up the goods at the shop (pickup) or find them next to you (delivery).
7. After the catalog closes, temporary spawn-place overrides are reverted.

If the catalog is closed without a purchase, the order is not considered placed and the delivery fee is not charged.

## Limitations

1. The catalog stays global for all points: the mod does not filter the assortment per selected shop.
2. There is no manual delivery-point selection on the map — delivery always targets the player position.
3. An order is completed successfully only after ALL of its loads finish; the purchase fact is confirmed by actual object creation (hooks on `VehicleLoadingData`/`PlaceableLoadingData`) bound to the current order; catalog close and finance events alone are not proof.
4. Per-pallet validation (terrain/collisions for each exact position) is not implemented yet: only the central delivery point is validated.
5. Single-player only.

Full check log: [docs/KNOWN_LIMITATIONS_RU.md](docs/KNOWN_LIMITATIONS_RU.md).
