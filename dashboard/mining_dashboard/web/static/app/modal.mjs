// Shared modal dialog (#1876): the "native platform feature over JS state" call Worker Inspect's
// own <dialog> already made (#518, workerview.mjs). showModal() gives focus-trapping, Escape, and
// focus-return-to-opener for free; ::backdrop replaces a hand-rolled overlay div.
//
// `onCancel` fires on the dialog's `cancel` event (Escape) and is the same handler callers wire to
// their Cancel/Close button. The default is ALWAYS prevented, so refusing a cancel (an upgrade or
// backup in flight) is just not acting on it, and closing means calling close() from inside
// `onCancel` — which fires the native `close` event and returns focus to the opener on its own.
import { Component, createRef, html } from "./preact.mjs";

export class Modal extends Component {
  constructor(props) {
    super(props);
    this.dialogRef = createRef();
    this.titleRef = createRef();
  }

  componentDidMount() {
    this.dialogRef.current?.showModal();
    this.titleRef.current?.focus();
  }

  close() {
    this.dialogRef.current?.close();
  }

  render() {
    const { title, onCancel, onClose, children } = this.props;
    return html`
      <dialog class="card config-modal" ref=${this.dialogRef} role="dialog" aria-modal="true"
              aria-label=${title} onCancel=${(e) => {
                e.preventDefault();
                onCancel?.();
              }} onClose=${onClose}>
        <h3 tabindex="-1" ref=${this.titleRef}>${title}</h3>
        ${children}
      </dialog>`;
  }
}
