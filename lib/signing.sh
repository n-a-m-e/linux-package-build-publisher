# shellcheck shell=bash

# GPG key setup, generation, import, export, and signing identity.

setup_gpg(){
  local fpr

  ensure_dir gpg-key
  chmod 700 gpg-key
  export GNUPGHOME="$PWD/gpg-key"

  gpg --batch --import gpg-key/private.asc
  gpg --batch --import gpg-key/public.asc

  fpr="$(cat gpg-key/fingerprint.txt)"
  write_output fingerprint "$fpr"
}

gpg_generate(){
  rm -rf gpg-key
  mkdir -p gpg-key
  chmod 700 gpg-key

  GNUPGHOME="$PWD/gpg-key" gpg --batch --generate-key < <(printf '%s\n' "$GPG_KEY_BATCH")
  GNUPGHOME="$PWD/gpg-key" gpg --armor --export-secret-keys >gpg-key/private.asc
  GNUPGHOME="$PWD/gpg-key" gpg --armor --export >gpg-key/public.asc
  GNUPGHOME="$PWD/gpg-key" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="fpr"{print $10; exit}' >gpg-key/fingerprint.txt
}

