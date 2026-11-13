```bash
sudo ./lansdev-hub.sh              # manage wifi hostspot and external HDD
sudo ./wifi-share.sh               # start wifi connection
```

> Note: `wifi-share.sh` (and `lansdev-hub.sh`) are the **legacy** hotspot scripts.
> The current Q-Spot uses its own hotspot managed by `q-spot.sh`:
>
> ```bash
> sudo ./q-spot.sh restart          # current Q-Spot hotspot (qspot0 + hostapd + dnsmasq)
> ```
>
> The legacy scripts manage a separate NetworkManager AP interface (`ap0`).
> If you still need the plain shareable hotspot, stop Q-Spot first, then run
> the legacy scripts.
