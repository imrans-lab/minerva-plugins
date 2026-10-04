module github.com/imrans-lab/minerva-plugins/docket

go 1.23.0

require (
 github.com/ProtonMail/go-crypto v1.5.2
 github.com/imrans-lab/minerva-plugins/shared v0.0.0
)

replace github.com/imrans-lab/minerva-plugins/shared => ../shared

require (
 github.com/klauspost/compress v1.17.11 // indirect
 github.com/cloudflare/circl v1.6.3 // indirect
 golang.org/x/crypto v0.41.0 // indirect
 golang.org/x/sys v0.35.0 // indirect
)
