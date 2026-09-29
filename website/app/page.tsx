import { ChargingWordmark } from "./charging-wordmark";
import { CopyCommand } from "./copy-command";
import { Trailer } from "./trailer";

const DOWNLOAD_URL = "https://github.com/EClinick/juice/releases/latest/download/Juice.dmg";

function AppleMark() {
  return <span className="apple-mark" aria-hidden="true">{""}</span>;
}

export default function Home() {
  return (
    <main>
      <div className="sheet">
        <section className="hero" aria-labelledby="hero-title" data-charge-stage>
          <nav className="nav" aria-label="Primary navigation">
            <a className="brand" href="#top" aria-label="Juice home">
              JUICE<span>®</span>
            </a>
            <a className="github-link" href="https://github.com/EClinick/juice">
              GitHub <span aria-hidden="true">↗</span>
            </a>
          </nav>

          <div className="product-stage" aria-label="MacBook notch">
            <div className="notch" />
          </div>

          <div id="top" className="hero-copy">
            <p className="eyebrow">A battery history for your Mac</p>
            <ChargingWordmark />
            <p className="subtitle">Know where your battery went.</p>
            <a className="download-button" href={DOWNLOAD_URL}>
              <AppleMark />
              Download for Mac
            </a>
            <p className="release-note">
              macOS 14+ · Apple silicon and Intel. Free and{" "}
              <a className="release-link" href="https://github.com/EClinick/juice">open source</a>.
            </p>
          </div>

          <a className="maker-link" href="https://x.com/EthanClinick">
            <span className="maker-link-label">By Ethan</span>
            <span className="maker-link-arrow" aria-hidden="true">↗</span>
          </a>
        </section>
      </div>

      <section className="trailer" aria-labelledby="trailer-title">
        <header className="trailer-header">
          <p className="trailer-eyebrow">The 19-second tour</p>
          <h2 id="trailer-title" className="trailer-title">
            See where it <span>went.</span>
          </h2>
        </header>

        <Trailer />

        <div className="trailer-cta">
          <a className="download-button download-button-light" href={DOWNLOAD_URL}>
            <AppleMark />
            Download for Mac
          </a>
          <div className="trailer-brew">
            <span>or</span>
            <CopyCommand command="brew install --cask EClinick/tap/juice" />
          </div>
        </div>
      </section>
    </main>
  );
}
