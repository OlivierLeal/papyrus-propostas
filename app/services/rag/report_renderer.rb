module Rag
  # Monta o HTML de conferência da ingestão (ver script/rag/report.rb).
  #
  # O relatório existe para responder três perguntas antes de qualquer coisa ir para o banco:
  # o papel de cada documento está certo? o corte em trechos ficou coerente? o que foi marcado
  # como sensível realmente é? Por isso ele mostra o texto integral de cada trecho, e não só
  # estatísticas — número agregado esconde justamente o erro que se quer achar.
  #
  # Trechos com dado identificável nascem ocultos: o arquivo fica no disco do usuário e pode
  # ser aberto em qualquer lugar, então o padrão é não expor CPF, registro profissional ou
  # contato sem uma ação deliberada.
  class ReportRenderer
    ROLE_COLORS = {
      "proposta_papyrus" => "#1d7874", "planilha_papyrus" => "#2a9d8f",
      "tr_cliente" => "#bc6c25", "anexo_tecnico" => "#8a5a44",
      "documento_contratual" => "#6a4c93", "modelo_documento" => "#4a6fa5",
      "planilha_cliente" => "#a4703c", "outro" => "#6c757d"
    }.freeze

    STATUS_LABELS = {
      ok: "texto nativo", ocr: "recuperado por OCR", needs_ocr: "escaneado, sem OCR",
      unsupported: "formato não suportado", empty: "sem conteúdo", failed: "ilegível"
    }.freeze

    def initialize(jobs, source:)
      @jobs = jobs
      @source = source
    end

    def call
      <<~HTML
        <!doctype html>
        <html lang="pt-BR">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Acervo RAG — Papyrus</title>
        <style>#{styles}</style>
        </head>
        <body>
        #{header}
        #{summary}
        #{@jobs.map { |job| render_job(job) }.join}
        <script>#{script}</script>
        </body>
        </html>
      HTML
    end

    private

    def documents = @jobs.flat_map(&:documents)
    def chunks = documents.flat_map(&:chunks)

    def header
      <<~HTML
        <header>
          <h1>Acervo RAG — conferência da ingestão</h1>
          <p class="sub">#{h(@source)} · gerado em #{Time.current.strftime('%d/%m/%Y %H:%M')}</p>
          <p class="warn">Nada foi gravado no banco nem enviado para embedding. Este arquivo é só para revisão.</p>
        </header>
      HTML
    end

    def summary
      indexable = documents.select(&:indexable?)
      voice = indexable.select { |doc| DocumentClassifier::VOICE_OF_PAPYRUS.include?(doc.role) }

      cards = [
        [ @jobs.size, "jobs" ],
        [ documents.size, "documentos" ],
        [ chunks.size, "trechos" ],
        [ voice.sum { |doc| doc.chunks.size }, "trechos na voz da Papyrus" ],
        [ chunks.count(&:sensitive), "trechos com dado identificável" ],
        [ documents.count { |doc| doc.item.superseded }, "revisões antigas (fora do índice)" ]
      ]

      <<~HTML
        <section class="cards">
          #{cards.map { |value, label| "<div class='card'><b>#{value}</b><span>#{label}</span></div>" }.join}
        </section>
        <section class="roles">
          #{role_bars}
        </section>
        <div class="controls">
          <input type="search" id="filter" placeholder="filtrar por arquivo, seção ou conteúdo...">
          <label><input type="checkbox" id="show-sensitive"> revelar trechos sensíveis</label>
          <label><input type="checkbox" id="only-voice"> só a voz da Papyrus</label>
        </div>
      HTML
    end

    def role_bars
      total = documents.sum { |doc| doc.chunks.size }.to_f
      return "" if total.zero?

      documents.group_by(&:role).sort_by { |_role, docs| -docs.sum { |d| d.chunks.size } }.map do |role, docs|
        count = docs.sum { |doc| doc.chunks.size }
        percentage = (count / total * 100).round(1)

        <<~HTML
          <div class="role-row">
            <span class="tag" style="background:#{ROLE_COLORS.fetch(role, '#6c757d')}">#{h(role)}</span>
            <div class="bar"><i style="width:#{percentage}%;background:#{ROLE_COLORS.fetch(role, '#6c757d')}"></i></div>
            <span class="num">#{docs.size} docs · #{count} trechos</span>
          </div>
        HTML
      end.join
    end

    def render_job(job)
      <<~HTML
        <section class="job">
          <h2>#{h(job.numero || '?')} — #{h(job.client_name || job.name)}</h2>
          <p class="sub">#{h(job.subject)} · #{job.documents.size} documentos</p>
          #{job.documents.sort_by { |doc| [ doc.role, doc.item.relative_path ] }.map { |doc| render_document(doc) }.join}
        </section>
      HTML
    end

    def render_document(document)
      item = document.item
      flags = []
      flags << "<span class='flag old'>revisão antiga</span>" if item.superseded
      flags << "<span class='flag'>#{h(STATUS_LABELS[document.status])}</span>" unless document.status == :ok
      flags << "<span class='flag'>papel via #{document.role_source}</span>"

      <<~HTML
        <details class="doc" data-role="#{h(document.role)}">
          <summary>
            <span class="tag" style="background:#{ROLE_COLORS.fetch(document.role, '#6c757d')}">#{h(document.role)}</span>
            <span class="name">#{h(File.basename(item.relative_path))}</span>
            <span class="count">#{document.chunks.size} trechos</span>
            #{flags.join}
          </summary>
          <p class="path">#{h(item.relative_path)}#{" · #{document.page_count} páginas" if document.page_count > 1}</p>
          #{document.error.present? ? "<p class='error'>#{h(document.error)}</p>" : ''}
          #{document.chunks.map { |chunk| render_chunk(chunk) }.join}
        </details>
      HTML
    end

    def render_chunk(chunk)
      reasons = chunk.sensitivity_reasons.join(", ")
      classes = [ "chunk" ]
      classes << "sensitive" if chunk.sensitive

      <<~HTML
        <article class="#{classes.join(' ')}">
          <div class="meta">
            <b>#{h([ chunk.section_number, chunk.section_title ].compact_blank.join('. ').presence || 'sem seção')}</b>
            <span>#{chunk.char_count} car · ~#{chunk.estimated_tokens} tokens</span>
            #{chunk.sensitive ? "<span class='flag sens'>sensível: #{h(reasons)}</span>" : ''}
            #{chunk.contains_pricing ? "<span class='flag price'>preço</span>" : ''}
          </div>
          <pre>#{h(chunk.content)}</pre>
        </article>
      HTML
    end

    def styles
      <<~CSS
        :root { --bg:#fbfaf8; --fg:#22201d; --muted:#6b6560; --line:#e3ded7; --card:#fff; }
        @media (prefers-color-scheme: dark) {
          :root { --bg:#171614; --fg:#eae6e0; --muted:#9a938b; --line:#302d29; --card:#1f1e1b; }
        }
        * { box-sizing:border-box; }
        body { margin:0; padding:2rem 1.5rem 4rem; background:var(--bg); color:var(--fg);
               font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif; }
        header, section, .controls { max-width:1100px; margin-inline:auto; }
        h1 { font-size:1.6rem; margin:0 0 .2rem; }
        h2 { font-size:1.15rem; margin:2.5rem 0 .2rem; }
        .sub { color:var(--muted); margin:.1rem 0 1rem; font-size:.9rem; }
        .warn { background:#fff3cd; color:#5c4500; border:1px solid #ffe08a; border-radius:8px;
                padding:.6rem .9rem; font-size:.88rem; }
        @media (prefers-color-scheme: dark) { .warn { background:#3a2f00; color:#ffe08a; border-color:#5c4a00; } }
        .cards { display:flex; flex-wrap:wrap; gap:.75rem; margin:1.5rem auto; }
        .card { background:var(--card); border:1px solid var(--line); border-radius:10px;
                padding:.8rem 1rem; min-width:130px; flex:1; }
        .card b { display:block; font-size:1.5rem; }
        .card span { color:var(--muted); font-size:.82rem; }
        .role-row { display:flex; align-items:center; gap:.7rem; margin:.35rem 0; }
        .bar { flex:1; height:8px; background:var(--line); border-radius:4px; overflow:hidden; }
        .bar i { display:block; height:100%; }
        .num { color:var(--muted); font-size:.82rem; white-space:nowrap; }
        .tag { color:#fff; padding:.12rem .5rem; border-radius:20px; font-size:.72rem;
               font-weight:600; white-space:nowrap; }
        .controls { display:flex; gap:1rem; align-items:center; flex-wrap:wrap; margin:1.5rem auto .5rem;
                    position:sticky; top:0; background:var(--bg); padding:.75rem 0; z-index:5;
                    border-bottom:1px solid var(--line); }
        .controls input[type=search] { flex:1; min-width:220px; padding:.5rem .75rem; border-radius:8px;
                                       border:1px solid var(--line); background:var(--card); color:var(--fg); }
        .controls label { font-size:.85rem; color:var(--muted); display:flex; gap:.35rem; align-items:center; }
        .job { max-width:1100px; margin-inline:auto; }
        .doc { background:var(--card); border:1px solid var(--line); border-radius:10px;
               margin:.5rem 0; padding:.3rem .9rem; }
        .doc summary { cursor:pointer; display:flex; gap:.6rem; align-items:center; flex-wrap:wrap;
                       padding:.5rem 0; }
        .doc .name { font-weight:600; }
        .doc .count, .path { color:var(--muted); font-size:.82rem; }
        .path { margin:.2rem 0 .8rem; word-break:break-all; }
        .flag { font-size:.72rem; color:var(--muted); border:1px solid var(--line);
                border-radius:20px; padding:.1rem .5rem; }
        .flag.old { color:#b54708; border-color:#f5c99b; }
        .flag.sens { color:#b42318; border-color:#f3b5b0; }
        .flag.price { color:#0b6b5e; border-color:#9fd8ce; }
        .error { color:#b42318; font-size:.85rem; }
        .chunk { border-top:1px solid var(--line); padding:.8rem 0; }
        .chunk .meta { display:flex; gap:.6rem; align-items:center; flex-wrap:wrap;
                       font-size:.8rem; color:var(--muted); margin-bottom:.4rem; }
        .chunk pre { margin:0; white-space:pre-wrap; word-break:break-word; font:13px/1.55 ui-monospace,monospace;
                     background:var(--bg); border:1px solid var(--line); border-radius:8px;
                     padding:.7rem .85rem; max-height:340px; overflow:auto; }
        .chunk.sensitive pre { filter:blur(5px); user-select:none; }
        body.reveal .chunk.sensitive pre { filter:none; user-select:auto; }
        .hidden { display:none !important; }
      CSS
    end

    def script
      <<~JS
        const filter = document.getElementById('filter');
        const reveal = document.getElementById('show-sensitive');
        const onlyVoice = document.getElementById('only-voice');
        const VOICE = #{DocumentClassifier::VOICE_OF_PAPYRUS.to_json};
        const docs = [...document.querySelectorAll('.doc')];

        reveal.addEventListener('change', () => document.body.classList.toggle('reveal', reveal.checked));

        function apply() {
          const term = filter.value.trim().toLowerCase();
          docs.forEach(doc => {
            const roleOk = !onlyVoice.checked || VOICE.includes(doc.dataset.role);
            const textOk = !term || doc.textContent.toLowerCase().includes(term);
            doc.classList.toggle('hidden', !(roleOk && textOk));
            if (term && roleOk && textOk) doc.open = true;
          });
          document.querySelectorAll('.job').forEach(job => {
            const visible = [...job.querySelectorAll('.doc')].some(d => !d.classList.contains('hidden'));
            job.classList.toggle('hidden', !visible);
          });
        }

        filter.addEventListener('input', apply);
        onlyVoice.addEventListener('change', apply);
      JS
    end

    def h(text) = ERB::Util.html_escape(text.to_s)
  end
end
