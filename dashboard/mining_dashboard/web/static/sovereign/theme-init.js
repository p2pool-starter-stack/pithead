(() => {
  let theme = "auto";
  try {
    const saved = localStorage.getItem("dashboardTheme");
    if (["light", "dark"].includes(saved)) theme = saved;
  } catch {}
  document.documentElement.dataset.theme = theme;
})();
