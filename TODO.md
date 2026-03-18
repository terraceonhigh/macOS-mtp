# AndroidFS — TODO

## High impact (UX friction)

- [ ] Volume shows as "127.0.0.1" in Finder sidebar — should show device name (e.g. "Pixel 6")
- [ ] Device name shows "Android Device" — fall back to `LIBMTP_Get_Modelname` when friendly name is empty
- [ ] Login item registration — offer to start at login on first launch via `SMAppService`

## Medium impact (reliability)

- [ ] Error recovery — detect bridge crash mid-session, auto-restart
- [ ] Handle detach during file transfer gracefully (don't hang Finder)
- [ ] Session recovery — reopen MTP session on corruption without full bridge restart

## Low impact (completeness)

- [ ] Multiple storage support (phones with SD cards → subdirectories under single mount)
- [ ] Notarization build configuration (hardened runtime + signing for distribution)
- [ ] Large directory performance (700+ entries block the session goroutine; consider async/paginated enumeration)

## Known friction points

- [x] "Unsecured Connection" dialog on mount — fixed with `kNAUIOptionNoUI` + guest auth
- [ ] PTPCamera must be killed before bridge can claim USB interface — works but inelegant
- [ ] `libusb_detach_kernel_driver` timeout adds ~5s on some connections
