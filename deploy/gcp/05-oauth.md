# Google OAuth setup (manual, ~15 minutes)

Two separate OAuth clients live in `warmbly-503807`. Warmbly keeps them apart on
purpose: the login client is a low-risk identity client, the mailbox client asks
for restricted Gmail scopes.

Everything else in this deployment is scripted. This part is not, because Google
does not expose OAuth client creation through `gcloud`.

## 0. Publishing status: keep it out of production

Console: **APIs & Services -> OAuth consent screen**

| Status | Users | Verification | CASA Tier 2 audit |
|---|---|---|---|
| Testing | 100 test users | none | none |
| Internal (Workspace org only) | unlimited in-org | exempt | exempt |
| In production (external) | unlimited | required | required for restricted scopes |

The mailbox client needs `gmail.modify` (warmup moves messages out of spam), a
**restricted** scope. Publishing externally triggers an annual CASA Tier 2
security assessment: months of work and real money.

Pick **Internal** if every mailbox lives in one Workspace org. Otherwise
**Testing**, and add each operator address under "Test users".

Testing-mode refresh tokens have historically expired after 7 days. If mailboxes
start disconnecting weekly, that is the cause, and the fix is moving to Internal
under a Workspace org.

## 1. Login client ("Sign in with Google" for the dashboard)

**Credentials -> Create credentials -> OAuth client ID -> Web application**

- Name: `warmbly-login`
- Authorized redirect URI:
  ```
  https://warmbly-backend-390860474553.us-central1.run.app/auth/google/callback
  ```
- Scopes: `openid`, `email`, `profile` (Warmbly requests `userinfo.email`)

Then store it:

```bash
cd deploy/gcp
./set-oauth-secret.sh google '<client-id>' '<client-secret>'
```

This client is optional. Email+password and passkeys work without it.

## 2. Mailbox client (connecting sending mailboxes)

**Credentials -> Create credentials -> OAuth client ID -> Web application**

- Name: `warmbly-mailbox`
- Authorized redirect URI:
  ```
  https://warmbly-backend-390860474553.us-central1.run.app/addresses/google/callback
  ```

Add these six scopes on the consent screen. This is what
`internal/config/inbox.go` actually requests, so anything missing here fails at
connect time:

```
https://www.googleapis.com/auth/gmail.compose
https://www.googleapis.com/auth/gmail.metadata
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/gmail.send
https://www.googleapis.com/auth/gmail.settings.basic
https://www.googleapis.com/auth/gmail.readonly
```

Note this is a longer list than the plan document assumed
(`gmail.send`/`modify`/`readonly`). `gmail.compose`, `gmail.metadata` and
`gmail.settings.basic` are also requested.

Store it:

```bash
./set-oauth-secret.sh box-google '<client-id>' '<client-secret>'
```

Then redeploy so the backend and the worker both pick the values up:

```bash
./07-deploy-run.sh && ./08-vm-services.sh
```

`BOX_GOOGLE_*` must be set on **both** the backend and every worker. The backend
runs the redirect flow; the worker refreshes tokens when it sends.

## 3. Enable the Gmail API

```bash
gcloud services enable gmail.googleapis.com --project warmbly-503807
```

## 4. Sending limits, for reference

| | Recipients/day | Per message |
|---|---|---|
| Free @gmail.com | 500 | 500 (API) |
| Workspace | 2,000 | 500 (API) |

Rolling 24h window, no midnight reset. These ceilings are irrelevant in
practice: safe cold-email volume is 20-50/day/mailbox. Scale by adding
mailboxes, never by pushing one mailbox harder.
