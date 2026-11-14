import { expect, test } from "./fixtures.mjs";

const config = {
  monero: { rpc_lan_access: false, zmq_lan_access: false },
  tari: { grpc_lan_access: false },
  _core_keys: [],
  _editable_keys: [],
  _confirm_keys: ["monero.rpc_lan_access", "monero.zmq_lan_access", "tari.grpc_lan_access"],
  _approval_keys: [],
  _default_keys: [],
};

async function controlRoutes(page) {
  const posted = { preview: null, commit: null, doctor: false };
  await page.route("**/api/config", (route) => route.fulfill({ json: config }));
  await page.route("**/api/control/preview", async (route) => {
    posted.preview = route.request().postDataJSON();
    await route.fulfill({
      json: {
        id: "r1",
        status: "previewed",
        changes: [{ msg: "monero.rpc_lan_access false → true" }],
      },
    });
  });
  await page.route("**/api/control/commit", async (route) => {
    posted.commit = route.request().postDataJSON();
    await route.fulfill({ json: { id: "r1", status: "applied" } });
  });
  await page.route("**/api/control/diag-doctor", async (route) => {
    posted.doctor = true;
    await route.fulfill({ status: 202, json: { id: "d1" } });
  });
  await page.route("**/api/control/result**", (route) =>
    route.fulfill({
      json: {
        id: "d1",
        status: "applied",
        doctor: {
          checks: [{ id: "lan-guard", status: "ok", message: "The LAN-only source rule is live." }],
        },
      },
    }),
  );
  return posted;
}

test("LAN access switches: address with copy, apply review, and the LAN rule check", async ({
  page,
  ui,
}) => {
  ui.state.control_enabled = true;
  const posted = await controlRoutes(page);
  await ui.openPreview("?page=settings");

  const group = page.getByRole("region", { name: "LAN access" });
  await expect(group.getByRole("heading", { name: "LAN access" })).toBeVisible();
  await expect(group).toContainText("never exposes a port to the internet");
  const rpc = group.getByRole("checkbox", { name: "Monero wallet RPC" });
  const zmq = group.getByRole("checkbox", { name: "Monero ZMQ" });
  const grpc = group.getByRole("checkbox", { name: "Tari gRPC" });
  await expect(rpc).not.toBeChecked();
  await expect(group.getByText("100.68.38.126:18081")).toHaveCount(0);

  await rpc.check();
  await expect(group.getByText("100.68.38.126:18081")).toBeVisible();
  await expect(group.getByRole("button", { name: "Copy", exact: true })).toBeVisible();
  const apply = group.getByRole("button", { name: "Review and apply changes" });
  await expect(apply).toBeVisible();

  await rpc.uncheck();
  await expect(apply).toHaveCount(0);
  await rpc.check();

  await apply.click();
  const dialog = page.getByRole("dialog", { name: "Review changes" });
  await expect(dialog.getByText("monero.rpc_lan_access false → true")).toBeVisible();
  await dialog.getByRole("button", { name: "Confirm & apply" }).click();
  await expect(group.getByText("Applied.")).toBeVisible();
  expect(posted.preview.config).toMatchObject({ monero: { rpc_lan_access: true } });
  expect(posted.commit).toEqual({ id: "r1" });

  await expect(group.getByText("The LAN-only source rule is live.")).toBeVisible();
  expect(posted.doctor).toBe(true);

  await zmq.check();
  await expect(group.getByText("100.68.38.126:18083")).toBeVisible();
  await grpc.check();
  await expect(group.getByText("100.68.38.126:18142")).toBeVisible();
});

test("LAN access switches explain the disconnected host", async ({ page, ui }) => {
  ui.state.control_enabled = false;
  await ui.openPreview("?page=settings");
  await expect(page.getByRole("heading", { name: "LAN access" })).toBeVisible();
  await expect(page.getByText("Sign in with an active session")).toBeVisible();
});
