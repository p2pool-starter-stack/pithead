import { safeNext } from "./login-next.mjs";

const form = document.getElementById("login-form");
const errorBox = document.getElementById("login-error");

function fail(message) {
  errorBox.textContent = message;
  errorBox.hidden = false;
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  errorBox.hidden = true;
  const button = form.querySelector("button");
  button.disabled = true;
  try {
    const response = await fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: form.username.value,
        password: form.password.value,
        remember: form.remember.checked,
      }),
    });
    if (response.ok) {
      location.assign(safeNext(location.search));
      return;
    }
    if (response.status === 401) fail("Wrong username or password.");
    else if (response.status === 429) fail("Too many attempts. Wait a minute and try again.");
    else fail("Sign-in is unavailable right now. Try again shortly.");
  } catch {
    fail("Could not reach the dashboard. Check your connection and try again.");
  } finally {
    button.disabled = false;
  }
});
