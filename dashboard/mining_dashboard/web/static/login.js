const error = document.querySelector(".login-error");
if (error && new URL(location.href).searchParams.get("error") === "1") error.hidden = false;

const form = document.querySelector("form");
form?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = form.querySelector("button[type=submit]");
  button.disabled = true;
  error.hidden = true;
  try {
    const response = await fetch(form.action, {
      method: "POST",
      body: new URLSearchParams(new FormData(form)),
      credentials: "same-origin",
    });
    if (!response.ok) throw new Error();
    location.assign(response.url || "/");
  } catch {
    error.hidden = false;
    button.disabled = false;
  }
});
