# Getting started with OSRA

> **Draft, not yet for customers.** Every step below is taken from the app as it is built today
> (`main` at `fe8d36f`, 7 November 2026). A few things a customer needs are not built yet, so this
> guide must not be published until the items in [`GUIDE-GAPS.md`](GUIDE-GAPS.md) are closed or the
> text is changed to match. The Arabic version is [`GETTING-STARTED.ar.md`](GETTING-STARTED.ar.md).

OSRA has two apps:

| App | Install it on | Store name |
|---|---|---|
| **OSRA: Parental Control** (the parent app) | Your own phone | Google Play |
| **OSRA Child: Parental Control** (the child app) | Every phone or tablet your child uses | Google Play |

Today both apps are for **Android**. The iPhone and iPad versions are coming later; this guide will
be updated when they are in the App Store.

---

## 1. Download the apps

1. On **your** phone, open Google Play, search for **OSRA: Parental Control**, and tap **Install**.
2. On **your child's** phone or tablet, open Google Play, search for **OSRA Child: Parental Control**,
   and tap **Install**. Do this on every device your child uses.

Keep your child's device next to you for the next steps. Setting up one device takes about five
minutes.

## 2. Create your family account (parent app)

1. Open **OSRA** on your phone and tap **Get started**.
2. Enter your email and a password of **at least 12 characters**. Open **Create account**, enter
   your name and a family name, and tap **Register**. If you already have an account, tap
   **Sign in** instead.

You are the **family owner**. Only the owner can add children.

## 3. Add your child

1. Enter your child's **name** and **birth year**.
2. Choose how you gave **parental consent**. OSRA needs this before it can protect a child.
3. Tap **Add child and continue**.

Add one profile per child, not per device. A child with a phone and a tablet is still **one** child
in OSRA. To add a brother or sister later, tap **Add child** on the dashboard.

## 4. Pair your child's first device

**On your phone** the app now shows a **QR code**, the same code as **six digits**, and a countdown.
The code works **once** and expires after **10 minutes**. If it runs out, tap **Regenerate**.

**On your child's device:**

1. Open **OSRA** (the child app).
2. Tap **Scan QR code** and point the camera at the QR code on your phone.
3. Check that the code shown matches the one on your phone. In **Device name**, type a name you will
   recognise, such as *Sara's phone* or *Sara's tablet*. This is the name you will see in your app.
4. Tap **Confirm and pair**. The child's device now says it is waiting for you.

If the camera cannot scan, type the six digits into **Pairing code** instead and tap
**Pair this device**.

**On your phone** a card appears: **A device is asking to join**. Tap **Allow** only if the device
it names is the one in front of you. If you do not recognise it, tap **Deny**: that code stops
working and you can make a new one.

## 5. Finish on your child's device

1. **Set the parent PIN.** Choose 4 to 8 digits and enter them twice. This PIN is asked for whenever
   someone tries to remove OSRA from the device, so do not tell your child.
2. **Turn on the permissions.** The app lists what it needs and opens each setting for you. Protection
   is complete only when every required item is on:
   - Accessibility service (blocks apps and enforces limits)
   - Usage access (counts screen time)
   - Display over other apps (shows the lock and pause screens)
   - Device admin (stops OSRA being uninstalled without your PIN)
   - Web filter (a VPN request; blocks sites and turns on SafeSearch)
   - Location, "Allow all the time" (locate the device and place alerts)
   - Private DNS set to Automatic or Off (a named provider would get around the web filter)

   Also recommended: battery set to **Unrestricted**, so commands arrive quickly, and USB debugging
   off.
3. On your phone, tap **My child has finished pairing**. When the device is found, you are done.

If you need to stop here, tap **Set up later**. You can pair from the dashboard whenever the device
is ready; protection starts only after pairing.

---

## 6. Add more devices for the same child

Your child can have as many devices as they use. Each one is paired to the **same child profile**,
one at a time:

1. Install **OSRA Child: Parental Control** on the new device (section 1).
2. In the parent app, open the dashboard and tap your **child's name**.
3. On the **Overview** tab, under **Devices**, tap **Pair a device**. A new QR code and six-digit
   code appear. Each device needs its own new code; a code works only once.
4. On the new device, do steps 4 and 5 above: scan, give it its own **Device name**, confirm, tap
   **Allow** on your phone, set the parent PIN (it can be the same PIN as on the other device), and
   turn on the permissions.

The new device now appears in your child's **Devices** list, with its battery, when it was last
seen, and its own **Ring**, **Lock**, **Unlock**, **Pause**, **Resume** and **Pause net**
buttons.

**What applies to all of the child's devices, and what does not:**

| Setting | Applies to |
|---|---|
| Rules: blocked apps and categories, bedtime, school hours, web filter | **Every** device of that child. Change them once. |
| Ring, Lock, Unlock, Pause, Resume | **The one device** whose button you tap. |
| Daily screen-time limit | Each device counts its own time for now: a 3-hour limit allows 3 hours on the phone **and** 3 hours on the tablet. |
| Parent PIN | Set on each device. |

## 7. Good to know

- **The code expired or "is already being used".** Tap **Regenerate** on your phone and scan the new
  code.
- **"Your parent declined this phone."** You tapped Deny. Tap **Regenerate** and pair again.
- **"Your parent needs to give consent…"** Open the child's profile, then **Parental consent**, and
  complete it.
- **Two devices look the same in the list.** Give each one a clear **Device name** when you pair it.
- **Another parent.** The owner can invite a second parent from **Family members** → **Invite member**; they manage the same
  children with their own login. They do not need to pair the devices again.
