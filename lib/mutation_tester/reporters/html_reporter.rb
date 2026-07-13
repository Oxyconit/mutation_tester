module MutationTester
  module Reporters
    class HtmlReporter < BaseReporter
      include ERB::Util

      STATUS_SORT_ORDER = %i[survived killed timeout stillborn error].freeze

      def generate
        output_file = File.join(@config.output_dir, 'mutation_report.html')
        html_content = ERB.new(template).result(binding)
        File.write(output_file, html_content)
        puts Rainbow("✓ HTML report saved to: #{output_file}").green
      end

      private

      def sorted_results
        @results.sort_by do |result|
          [STATUS_SORT_ORDER.index(status_of(result)) || STATUS_SORT_ORDER.size, result[:line]]
        end
      end

      def ungrouped_results
        sorted_results.reject { |result| status_of(result) == :survived }
      end

      def group_location_label(group)
        if @config.show_file_path
          "#{h(group[:file_path])}:#{group[:line]}"
        else
          "Line #{group[:line]}"
        end
      end

      def group_types_label(group)
        group[:mutations].map { |m| m[:type].to_s.capitalize }.uniq.join(', ')
      end

      def diff_css_class(kind)
        { hunk: 'hunk', context: 'context', removed: 'original', added: 'mutated' }.fetch(kind)
      end

      def diff_marker_char(kind)
        { removed: '-', added: '+' }.fetch(kind, ' ')
      end

      def template
        <<~'HTML'
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Mutation Testing Report</title>
            <link rel="preconnect" href="https://fonts.googleapis.com">
            <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
            <style>
              :root {
                --bg-main: #0f172a;
                --bg-card: #1e293b;
                --bg-card-hover: #334155;
                --text-primary: #f8fafc;
                --text-secondary: #94a3b8;
                --text-muted: #64748b;
                --border-color: #334155;
                --accent-primary: #3b82f6;
                --accent-success: #10b981;
                --accent-danger: #ef4444;
                --accent-warning: #f59e0b;
                --gradient-bg: radial-gradient(circle at top right, #1e293b 0%, #0f172a 100%);
                --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.05);
                --shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
                --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1);
                --shadow-glow: 0 0 20px rgba(59, 130, 246, 0.15);
              }

              * { margin: 0; padding: 0; box-sizing: border-box; }

              body {
                font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
                background: var(--bg-main);
                color: var(--text-primary);
                line-height: 1.6;
                min-height: 100vh;
              }

              .layout {
                max-width: 1400px;
                margin: 0 auto;
                padding: 40px 20px;
              }

              /* Header */
              .header {
                display: flex;
                justify-content: space-between;
                align-items: flex-start;
                margin-bottom: 60px;
                padding-bottom: 20px;
                border-bottom: 1px solid var(--border-color);
              }

              .brand h1 {
                font-size: 2.5rem;
                font-weight: 700;
                background: linear-gradient(135deg, #60a5fa 0%, #3b82f6 100%);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
                margin-bottom: 8px;
                letter-spacing: -0.02em;
              }

              .brand-meta {
                color: var(--text-secondary);
                font-size: 0.95rem;
                display: flex;
                gap: 15px;
                align-items: center;
              }

              .version-badge {
                background: rgba(59, 130, 246, 0.1);
                color: #60a5fa;
                padding: 4px 12px;
                border-radius: 20px;
                font-size: 0.8rem;
                font-weight: 600;
              }

              .report-meta {
                text-align: right;
                color: var(--text-secondary);
                font-size: 0.9rem;
              }

              .interrupted-banner {
                display: flex;
                align-items: center;
                gap: 12px;
                background: rgba(245, 158, 11, 0.12);
                border: 1px solid var(--accent-warning);
                border-radius: 12px;
                color: var(--accent-warning);
                font-weight: 600;
                padding: 16px 20px;
                margin-bottom: 40px;
              }

              .interrupted-banner small {
                color: var(--text-secondary);
                font-weight: 400;
              }

              /* Summary Stats */
              .summary-grid {
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                gap: 24px;
                margin-bottom: 60px;
              }

              .stat-card {
                background: var(--bg-card);
                border: 1px solid var(--border-color);
                border-radius: 16px;
                padding: 24px;
                transition: all 0.3s ease;
                position: relative;
                overflow: hidden;
              }

              .stat-card:hover {
                transform: translateY(-4px);
                border-color: var(--text-secondary);
                box-shadow: var(--shadow-glow);
              }

              .stat-card::before {
                content: '';
                position: absolute;
                top: 0;
                left: 0;
                width: 100%;
                height: 4px;
                background: var(--card-color, var(--text-muted));
              }

              .stat-label {
                color: var(--text-secondary);
                font-size: 0.85rem;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                font-weight: 600;
                margin-bottom: 12px;
              }

              .stat-value {
                font-size: 2.5rem;
                font-weight: 700;
                color: var(--text-primary);
                line-height: 1;
              }

              .stat-sub {
                margin-top: 8px;
                font-size: 0.9rem;
                color: var(--text-muted);
              }

              /* Score Card Special Styling */
              .stat-card.score {
                grid-column: span 1;
                background: linear-gradient(145deg, var(--bg-card) 0%, rgba(30, 41, 59, 0.8) 100%);
              }

              .score-ring {
                position: relative;
                display: inline-flex;
                align-items: center;
                justify-content: center;
              }

              /* Filters */
              .controls {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 30px;
                background: var(--bg-card);
                padding: 8px;
                border-radius: 12px;
                border: 1px solid var(--border-color);
                width: fit-content;
              }

              .filter-btn {
                background: transparent;
                border: none;
                color: var(--text-secondary);
                padding: 10px 24px;
                border-radius: 8px;
                cursor: pointer;
                font-weight: 600;
                font-size: 0.95rem;
                transition: all 0.2s ease;
                font-family: inherit;
              }

              .filter-btn:hover {
                color: var(--text-primary);
              }

              .filter-btn.active {
                background: var(--bg-main);
                color: var(--text-primary);
                box-shadow: var(--shadow-sm);
              }

              .filter-count {
                background: rgba(255,255,255,0.1);
                padding: 2px 8px;
                border-radius: 12px;
                font-size: 0.8em;
                margin-left: 8px;
              }

              /* Mutation List */
              .mutation-list {
                display: flex;
                flex-direction: column;
                gap: 20px;
              }

              .mutation-item {
                background: var(--bg-card);
                border: 1px solid var(--border-color);
                border-radius: 12px;
                overflow: hidden;
                transition: all 0.3s ease;
              }

              .mutation-item:hover {
                border-color: var(--text-secondary);
              }

              .mutation-header {
                padding: 20px 24px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                background: rgba(255,255,255,0.02);
                border-bottom: 1px solid var(--border-color);
                cursor: pointer;
              }

              .mutation-id {
                font-family: 'JetBrains Mono', monospace;
                color: var(--text-secondary);
                font-size: 0.9rem;
              }

              .status-badge {
                padding: 6px 16px;
                border-radius: 20px;
                font-size: 0.85rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.05em;
              }

              .status-killed {
                background: rgba(16, 185, 129, 0.15);
                color: #34d399;
                border: 1px solid rgba(16, 185, 129, 0.2);
              }

              .status-survived {
                background: rgba(239, 68, 68, 0.15);
                color: #f87171;
                border: 1px solid rgba(239, 68, 68, 0.2);
              }

              .status-timeout {
                background: rgba(245, 158, 11, 0.15);
                color: #fbbf24;
                border: 1px solid rgba(245, 158, 11, 0.2);
              }

              .status-stillborn {
                background: rgba(148, 163, 184, 0.15);
                color: #cbd5e1;
                border: 1px solid rgba(148, 163, 184, 0.2);
              }

              .status-error {
                background: rgba(168, 85, 247, 0.15);
                color: #c084fc;
                border: 1px solid rgba(168, 85, 247, 0.2);
              }

              /* Category breakdown */
              .category-bar {
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
                margin-bottom: 40px;
              }

              .category-chip {
                background: var(--bg-card);
                border: 1px solid var(--border-color);
                border-radius: 20px;
                padding: 8px 18px;
                font-size: 0.9rem;
                color: var(--text-secondary);
                display: flex;
                gap: 8px;
                align-items: center;
              }

              .category-chip b {
                color: var(--text-primary);
                font-weight: 700;
              }

              .mutation-content {
                padding: 24px;
              }

              .info-grid {
                display: grid;
                grid-template-columns: auto 1fr;
                gap: 16px 32px;
                margin-bottom: 24px;
              }

              .info-label {
                color: var(--text-muted);
                font-weight: 500;
                font-size: 0.9rem;
              }

              .info-value {
                color: var(--text-primary);
                font-family: 'JetBrains Mono', monospace;
                font-size: 0.9rem;
              }

              .code-diff {
                background: #000;
                border-radius: 8px;
                padding: 20px;
                font-family: 'JetBrains Mono', monospace;
                font-size: 0.9rem;
                border: 1px solid var(--border-color);
                position: relative;
              }

              .diff-line {
                display: flex;
                padding: 2px 0;
              }

              .diff-line.original {
                color: #f87171;
                background: rgba(239, 68, 68, 0.1);
              }

              .diff-line.mutated {
                color: #34d399;
                background: rgba(16, 185, 129, 0.1);
              }

              .diff-line.context {
                color: var(--text-secondary);
              }

              .diff-line.hunk {
                color: var(--text-muted);
              }

              .diff-variant-ref {
                color: var(--text-muted);
                margin-left: 12px;
                font-size: 0.8em;
              }

              .variant-badge {
                color: var(--text-secondary);
                font-family: 'JetBrains Mono', monospace;
                font-size: 0.85rem;
              }

              .diff-marker {
                width: 24px;
                display: inline-block;
                text-align: center;
                opacity: 0.5;
                user-select: none;
              }

              .suggestion-box {
                margin-top: 20px;
                background: rgba(245, 158, 11, 0.1);
                border: 1px solid rgba(245, 158, 11, 0.2);
                padding: 16px;
                border-radius: 8px;
                display: flex;
                gap: 12px;
                align-items: flex-start;
              }

              .suggestion-icon {
                font-size: 1.2rem;
              }

              .suggestion-text {
                color: #fbbf24;
                font-size: 0.95rem;
              }

              /* Responsive */
              @media (max-width: 1024px) {
                .summary-grid {
                  grid-template-columns: repeat(2, 1fr);
                }
              }

              @media (max-width: 640px) {
                .summary-grid {
                  grid-template-columns: 1fr;
                }
                .header {
                  flex-direction: column;
                  gap: 20px;
                }
                .report-meta {
                  text-align: left;
                }
                .controls {
                  width: 100%;
                  overflow-x: auto;
                }
              }
            </style>
          </head>
          <body>
            <div class="layout">
              <header class="header">
                <div class="brand">
                  <h1>Mutation Report</h1>
                  <div class="brand-meta">
                    <span class="version-badge">v<%= MutationTester::VERSION %></span>
                    <span><%= h(@source_file) %></span>
                  </div>
                </div>
                <div class="report-meta">
                  <p>Generated <%= Time.now.strftime('%B %d, %Y') %></p>
                  <p style="color: var(--text-muted); font-size: 0.85rem; margin-top: 4px">
                    <%= Time.now.strftime('%H:%M:%S') %>
                  </p>
                </div>
              </header>

              <% if interrupted? %>
              <div class="interrupted-banner">
                <span>🛑 Interrupted run</span>
                <small>The run was stopped early by --fail-fast after the first surviving mutant; this report covers only the mutations processed before the interruption.</small>
              </div>
              <% end %>

              <div class="summary-grid">
                <div class="stat-card" style="--card-color: var(--accent-primary)">
                  <div class="stat-label">Total Mutations</div>
                  <div class="stat-value"><%= total_count %></div>
                  <div class="stat-sub">Analyzed points</div>
                </div>

                <div class="stat-card" style="--card-color: var(--accent-success)">
                  <div class="stat-label">Killed</div>
                  <div class="stat-value" style="color: var(--accent-success)"><%= killed_count %></div>
                  <div class="stat-sub"><%= total_count > 0 ? (killed_count.to_f / total_count * 100).round(1) : 0.0 %>% coverage</div>
                </div>

                <div class="stat-card" style="--card-color: var(--accent-danger)">
                  <div class="stat-label">Survived</div>
                  <div class="stat-value" style="color: var(--accent-danger)"><%= survived_count %></div>
                  <div class="stat-sub">Potential gaps</div>
                </div>

                <div class="stat-card score" style="--card-color: <%= mutation_score >= 80 ? 'var(--accent-success)' : 'var(--accent-warning)' %>">
                  <div class="stat-label">Mutation Score</div>
                  <div class="stat-value"><%= mutation_score %>%</div>
                  <div class="stat-sub">Quality: <%= quality_rating %></div>
                </div>
              </div>

              <div class="category-bar">
                <span class="category-chip status-killed">Killed <b><%= killed_count %></b></span>
                <span class="category-chip status-survived">Survived <b><%= survived_count %></b></span>
                <span class="category-chip status-timeout">Timeout <b><%= timeout_count %></b></span>
                <span class="category-chip status-stillborn">Stillborn <b><%= stillborn_count %></b></span>
                <span class="category-chip status-error">Error <b><%= error_count %></b></span>
              </div>

              <div class="controls">
                <button class="filter-btn active" onclick="filterMutations('all', this)">
                  All <span class="filter-count"><%= total_count %></span>
                </button>
                <button class="filter-btn" onclick="filterMutations('killed', this)">
                  Killed <span class="filter-count"><%= killed_count %></span>
                </button>
                <button class="filter-btn" onclick="filterMutations('survived', this)">
                  Survived <span class="filter-count"><%= survived_count %></span>
                </button>
                <button class="filter-btn" onclick="filterMutations('timeout', this)">
                  Timeout <span class="filter-count"><%= timeout_count %></span>
                </button>
                <button class="filter-btn" onclick="filterMutations('stillborn', this)">
                  Stillborn <span class="filter-count"><%= stillborn_count %></span>
                </button>
                <button class="filter-btn" onclick="filterMutations('error', this)">
                  Error <span class="filter-count"><%= error_count %></span>
                </button>
              </div>

              <div class="mutation-list">
                <% survivor_groups.each do |group| %>
                  <% variants = group[:mutations] %>
                  <div class="mutation-item" data-status="survived">
                    <div class="mutation-header" onclick="toggleDetails(this)">
                      <div style="display: flex; align-items: center; gap: 16px;">
                        <span class="status-badge status-survived">Survived</span>
                        <span class="mutation-id">
                          <%= group_location_label(group) %><%= " (#{variants.size} variants)" if variants.size > 1 %>
                        </span>
                      </div>
                      <span style="color: var(--text-muted); font-size: 0.9rem;">
                        <%= h(group_types_label(group)) %>
                      </span>
                    </div>

                    <div class="mutation-content">
                      <div class="info-grid">
                        <% variants.each do |mutation| %>
                          <div class="info-label"><span class="variant-badge">#<%= mutation[:id] %> <%= h(mutation[:type].to_s) %></span></div>
                          <div class="info-value"><%= h(mutation[:description]) %></div>
                        <% end %>
                      </div>

                      <div class="code-diff">
                        <% diff_lines(variants).each do |kind, text, variant| %>
                          <div class="diff-line <%= diff_css_class(kind) %>"><span class="diff-marker"><%= diff_marker_char(kind) %></span><%= h(text) %><% if variant && variants.size > 1 %><span class="diff-variant-ref">#<%= variant[:id] %></span><% end %></div>
                        <% end %>
                      </div>

                      <div class="suggestion-box">
                        <span class="suggestion-icon">💡</span>
                        <div class="suggestion-text">
                          <strong>Suggestion:</strong>
                          <% variants.each do |mutation| %>
                            Add a test case to verify the behavior when <%= h(mutation[:description].downcase) %>.
                          <% end %>
                          The code was mutated but your tests still passed.
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
                <% ungrouped_results.each do |mutation| %>
                  <% status = status_of(mutation) %>
                  <div class="mutation-item" data-status="<%= status %>">
                    <div class="mutation-header" onclick="toggleDetails(this)">
                      <div style="display: flex; align-items: center; gap: 16px;">
                        <span class="status-badge status-<%= status %>">
                          <%= status.to_s.capitalize %>
                        </span>
                        <span class="mutation-id">
                          <%= @config.show_file_path ? "#{h(mutation[:file_path])}:#{mutation[:line]}" : "Line #{mutation[:line]}" %>
                        </span>
                      </div>
                      <span style="color: var(--text-muted); font-size: 0.9rem;">
                        <%= h(mutation[:type].to_s.capitalize) %>
                      </span>
                    </div>

                    <div class="mutation-content">
                      <div class="info-grid">
                        <div class="info-label">Description</div>
                        <div class="info-value"><%= h(mutation[:description]) %></div>
                      </div>

                      <div class="code-diff">
                        <% if status == :timeout %>
                          <% diff_lines([mutation]).each do |kind, text, _variant| %>
                            <div class="diff-line <%= diff_css_class(kind) %>"><span class="diff-marker"><%= diff_marker_char(kind) %></span><%= h(text) %></div>
                          <% end %>
                        <% elsif mutation[:source_line] && mutation[:mutated_line] %>
                          <div class="diff-line original">
                            <span class="diff-marker">-</span>
                            <%= h(mutation[:source_line]) %>
                          </div>
                          <div class="diff-line mutated">
                            <span class="diff-marker">+</span>
                            <%= h(mutation[:mutated_line]) %>
                          </div>
                        <% else %>
                          <div class="diff-line original">
                            <span class="diff-marker">-</span>
                            <%= h(mutation[:original]) %>
                          </div>
                          <div class="diff-line mutated">
                            <span class="diff-marker">+</span>
                            <%= h(mutation[:mutated]) %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <script>
              function filterMutations(filter, button) {
                const items = document.querySelectorAll('.mutation-item');
                const buttons = document.querySelectorAll('.filter-btn');
                
                buttons.forEach(btn => btn.classList.remove('active'));
                button.classList.add('active');
                
                items.forEach(item => {
                  if (filter === 'all') {
                    item.style.display = 'block';
                  } else {
                    item.style.display = item.dataset.status === filter ? 'block' : 'none';
                  }
                });
              }

              function toggleDetails(header) {
                // Optional: Add collapse/expand functionality if list is too long
                // Currently always expanded as per design preference for visibility
              }
            </script>
          </body>
          </html>
        HTML
      end
    end
  end
end
