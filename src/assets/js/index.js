class Filter {
    constructor() {
        const url = new URL(window.location);
        this.startDate = url.searchParams.get('start_date');
        this.endDate = url.searchParams.get('end_date');

        this.conversion = url.searchParams.get('conversion');
        if (!this.conversion) this.conversion = 'units';
        this.interval = url.searchParams.get('interval');
        if (!this.interval) this.interval = 'week';
    }

    getSearchParams() {
        const params = new URLSearchParams();

        if (this.startDate) params.set('start_date', this.startDate);
        if (this.endDate) params.set('end_date', this.endDate);

        if (this.conversion) params.set('conversion', this.conversion);
        if (this.interval) params.set('interval', this.interval);

        return params;
    }

    getQueryString() {
        const params = this.getSearchParams();
        return params.toString() ? `?${params.toString()}` : '';
    }
}

const Routes = {
    Journal: (account) => ({ type: "Journal", account }),
    BalanceSheet: () => ({ type: "BalanceSheet" }),
    IncomeStatement: () => ({ type: "IncomeStatement" }),
};

class Router {
    constructor() {
        const url = new URL(window.location);
        this.setRoute(url.pathname);
    }

    setRoute(path) {
        const journalMatch = path.match(/^\/journal\/(.+)$/);
        if (journalMatch) {
            this.route = Routes.Journal(decodeURIComponent(journalMatch[1]));
            return;
        }
        if (path.match(/^\/balance_sheet$/)) {
            this.route = Routes.BalanceSheet();
            return
        }
        if (path.match(/^\/income_statement$/)) {
            this.route = Routes.IncomeStatement();
            return
        }
        this.route = null
    }

    generatePathname() {
        switch (this.route.type) {
            case "Journal":
                return `/journal/${this.route.account}`;
            case "BalanceSheet":
                return "/balance_sheet";
            case "IncomeStatement":
                return "/income_statement";
            default:
                return "/";
        }
    }

    getCrumbs() {
        switch (this.route.type) {
            case "Journal":
                return this.route.account;
            case "BalanceSheet":
                return "Balance Sheet";
            case "IncomeStatement":
                return "Income Statement";
            default:
                return "";
        }
    }
}

document.addEventListener('alpine:init', () => {
    Alpine.data('app', () => ({
        loading: false,
        router: new Router(),
        filter: new Filter(),
        eventSource: null,
        plotData: [],

        init() {
            if (this.router.route) {
                this.establishSSEConnection(this.router.route);
            }

            window.addEventListener('beforeunload', () => {
                this.closeExistingConnection();
            });

            window.addEventListener('popstate', (_event) => {
                this.router = new Router();
                this.filter = new Filter();
                this.establishSSEConnection();

            });

            this.$watch('filter', (value) => {
                const url = new URL(window.location);
                url.search = value.getQueryString();
                history.pushState({}, '', url);
                this.establishSSEConnection();
            });
        },

        closeExistingConnection() {
            if (this.eventSource) {
                this.eventSource.close();
                this.eventSource = null;
            }
        },

        navigate(path) {
            this.router.setRoute(path);
            const url = new URL(window.location);
            url.pathname = this.router.generatePathname();
            history.pushState({}, '', url);
            this.establishSSEConnection();
        },

        establishSSEConnection() {
            const source = "/sse" + this.router.generatePathname() + this.filter.getQueryString();

            this.closeExistingConnection();
            this.loading = true;
            this.eventSource = new EventSource(source);

            this.eventSource.onmessage = (event) => {
                this.loading = false;
                const contentElement = this.$refs.content;
                if (contentElement) {
                    const journal = contentElement.querySelector('.journal');
                    const scrollPos = journal ? journal.scrollTop : 0;
                    contentElement.innerHTML = event.data;
                    const newJournal = contentElement.querySelector('.journal');
                    if (newJournal) {
                        newJournal.scrollTop = scrollPos;
                    }
                }
            };

            this.eventSource.addEventListener('plot_points', (event) => {
                this.plotData = JSON.parse(event.data);
            })

            this.eventSource.onerror = (event) => {
                console.error('SSE connection error:', event);
                this.closeExistingConnection();
            };
        },
    }));

    Alpine.data('d3', () => {
        const margin = {
            top: 10,
            right: 30,
            bottom: 30,
            left: 50
        };

        const svg = d3.select("#d3 svg");
        const tooltip = d3.select("#d3 .tooltip");

        const xGroup = svg.append("g").attr("class", "sans");
        const yGroup = svg.append("g").attr("class", "mono");

        const chart = svg.append("g");

        // Grid lines group
        const grid = svg.append("g").attr("class", "grid");
        const hLine = grid
            .append("line")
            .attr("stroke", "hsl(0deg 0% 70% / 0.8)")
            .attr("stroke-width", "1")
            .style("display", "none");
        const vLine = grid
            .append("line")
            .attr("stroke", "hsl(0deg 0% 70% / 0.8)")
            .attr("stroke-width", "1")
            .style("display", "none");

        return {

            init() {
                this.$watch('plotData', (newData) => {
                    if (newData) {
                        this.updateChart(newData);
                    }
                });
            },

            updateChart(alpineData) {

                const data = [];

                alpineData.forEach((txn) => {
                    data.push({
                        hash: txn.hash,
                        date: new Date(txn.date),
                        balance: txn.balance,
                        balance_rendered: txn.balance_rendered,
                        currency: txn.currency,
                    })
                });

                // Group data by currency
                const dataByCurrency = d3.group(data, d => d.currency);
                const currencies = Array.from(dataByCurrency.keys());

                // Create color scale for currencies
                const colorScale = d3.scaleOrdinal()
                    .domain(currencies)
                    .range(d3.schemeSet2);

                const width = document.querySelector("#d3 svg").clientWidth;
                const height = width / 5;

                svg.attr("viewBox", `${-margin.left} ${-margin.top} ${width + margin.left + margin.right} ${height + margin.top + margin.bottom}`);

                xGroup.attr("transform", `translate(0,${height})`);

                const x = d3
                    .scaleUtc()
                    .domain(d3.extent(data, (txn) => txn.date))
                    .nice()
                    .range([0, width]);

                const y = d3
                    .scaleLinear()
                    .domain(d3.extent(data, (txn) => txn.balance))
                    .nice()
                    .range([height, 0]);

                d3.selectAll('.vertical').remove();
                d3.selectAll('.horizontal').remove();
                d3.selectAll('.circle').remove();
                currencies.forEach((currency) => {
                    updateCurrency(currency, colorScale(currency), chart, dataByCurrency.get(currency), x, y);
                });

                // Update legend
                updateLegend(currencies, colorScale);

                const circles = d3.selectAll(".circle");

                xGroup
                    .call(d3.axisBottom(x));

                yGroup
                    .call(d3.axisLeft(y).tickFormat(d3.format("~s")));

                // Invisible rectangle for mouse events
                svg.select("rect").remove();
                svg
                    .append("rect")
                    .attr("width", width)
                    .attr("height", height)
                    .attr("fill", "none")
                    .attr("pointer-events", "all")
                    .on("mousemove", function(event) {
                        // Get mouse position relative to SVG
                        const [mx, my] = d3.pointer(event, svg.node());

                        // Find closest point
                        let closest = null;
                        let closestIndex = -1;
                        let minDist = Infinity;
                        let i = 0
                        currencies.forEach((currency) => {
                            dataByCurrency.get(currency).forEach((d) => {
                                const px = x(d.date);
                                const py = y(d.balance);
                                const dist = Math.sqrt((mx - px) ** 2 + (my - py) ** 2);
                                if (dist < minDist) {
                                    minDist = dist;
                                    closest = d;
                                    closestIndex = i;
                                }
                                i += 1
                            });
                        });

                        circles.attr("fill", (d) => colorScale(d.currency));

                        if (minDist <= 20) {
                            const px = x(closest.date);
                            const py = y(closest.balance);
                            circles.filter((_, i) => i === closestIndex).attr("fill", "white").raise();

                            tooltip
                                .style("display", "block")
                                .style("left", `${event.pageX + 10}px`)
                                .style("top", `${event.pageY - 10}px`)
                                .text(`${closest.date.toISOString().split('T')[0]}: ${closest.balance_rendered} ${closest.currency}`);

                            hLine
                                .style("display", "block")
                                .attr("x1", 0)
                                .attr("y1", py)
                                .attr("x2", Math.max(0, px - 2))
                                .attr("y2", py);
                            vLine
                                .style("display", "block")
                                .attr("x1", px)
                                .attr("y1", height)
                                .attr("x2", px)
                                .attr("y2", Math.min(py + 2, height));
                        } else {
                            tooltip.style("display", "none");
                            hLine.style("display", "none");
                            vLine.style("display", "none");
                        }
                    })
                    .on("mouseleave", () => {
                        tooltip.style("display", "none");
                        hLine.style("display", "none");
                        vLine.style("display", "none");
                        circles.attr("fill", (d) => colorScale(d.currency));
                    });
            }
        }
    });

    Alpine.data('nav', (items) => ({
        isOpen: false,
        query: '',
        items: items,
        results: [],
        index: 0,

        open() {
            if (this.isOpen) {
                return;
            }
            this.isOpen = true;
            this.query = '';
            this.search();
        },

        close() {
            this.isOpen = false;
        },

        search() {
            const results = fuzzysort.go(this.query, this.items, {
                all: true,
                key: 'text',
                scoreFn: (r) => r.score * r.obj.weight,
            });

            this.results = results.map((result, i) => ({
                route: result.obj.route,
                html: result.highlight('<mark>', '</mark>'),
                index: i,
            }));

            this.index = 0;
            document.querySelector('.results').scrollTop = 0;
        },

        down() {
            this.index = (this.index + 1) % this.results.length;
            this.scrollIntoView();
        },

        up() {
            this.index = (this.index - 1 + this.results.length) % this.results.length;
            this.scrollIntoView();
        },

        scrollIntoView() {
            const el = document.querySelectorAll('nav .result')[this.index];
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
        }

    }));

    Alpine.store('txOpen', {
        open: localStorage.getItem('txOpen') ? JSON.parse(localStorage.getItem('txOpen')) : {},
        toggle(index) {
            if (this.open[index] === undefined) {
                this.open[index] = false;
            }
            this.open[index] = !this.open[index];
            if (!this.open[index]) {
                delete this.open[index];
            }
            localStorage.setItem('txOpen', JSON.stringify(this.open));
        }
    });

    Alpine.store('accountCollapsed', {
        init() {
            const saved = localStorage.getItem('accountCollapsed');
            if (saved) this.collapsed = new Set(JSON.parse(saved));
            Alpine.effect(() => {
                localStorage.setItem('accountCollapsed', JSON.stringify([...this.collapsed]));
            });
        },

        collapsed: new Set(),

        toggle(account) {
            if (this.collapsed.has(account)) {
                this.collapsed.delete(account);
            } else {
                this.collapsed.add(account);
            }
        },

        isExpanded(account) {
            return !this.collapsed.has(account);
        },

        isVisible(account) {
            const parts = account.split(':');
            for (let i = 1; i < parts.length; i++) {
                const prefix = parts.slice(0, i).join(':');
                if (this.collapsed.has(prefix)) {
                    return false;
                }
            }
            return true;
        }
    })
});

function updateLegend(currencies, colorScale) {
    const legend = d3.select("#legend");

    legend.selectAll(".legend-item").remove();
    legend.selectAll(".legend-item")
        .data(currencies)
        .enter()
        .append("div")
        .attr("class", "legend-item")
        .attr("font-size", "12px")
        .each(function(d) {
            d3.select(this)
                .append("span")
                .attr("class", "legend-value")
                .style("border-radius", "4px")
                .style("width", "8px")
                .style("height", "8px")
                .style("background-color", colorScale(d));

            d3.select(this)
                .append("span")
                .attr("class", "legend-label")
                .text(d);
        });
}

function updateCurrency(currency, color, chart, data, x, y) {
    var desaturated = d3.hsl(color);
    desaturated.s = 0.0;
    desaturated.l += 0.1;

    const lineWidth = 1.5;
    const circleRadius = 1.5;

    chart
        .selectAll(`.vertical-${currency}`)
        .data(data.slice(1), (d) => d.hash) // From second point onward
        .enter()
        .append("line")
        .attr("class", `vertical vertical-${currency}`)
        .attr("stroke", desaturated)
        .attr("stroke-width", lineWidth)
        .attr("stroke-dasharray", "1.5,3")
        .attr("x1", (d, _) => x(d.date))
        .attr("y1", (_, i) => y(data[i].balance)) // Previous y
        .attr("x2", (d, _) => x(d.date))
        .attr("y2", (d, _) => y(d.balance));

    chart
        .selectAll(`.horizontal-${currency}`)
        .data(data, (d) => d.hash) // One less than points
        .enter()
        .append("line")
        .attr("class", `horizontal horizontal-${currency}`)
        .attr("stroke", color)
        .attr("stroke-width", lineWidth)
        .attr("x1", (d, _) => x(d.date))
        .attr("y1", (d, _) => y(d.balance))
        .attr("x2", (_, i) => (i < data.length - 1) ? x(data[i + 1].date) : x.range()[1]) // Next x
        .attr("y2", (d, _) => y(d.balance));

    // Circles at each point
    chart
        .selectAll(`circle-${currency}`)
        .data(data, (d) => d.hash)
        .enter()
        .append("circle")
        .attr("class", `circle circle-${currency}`)
        .attr("stroke", color)
        .attr("stroke-width", lineWidth)
        .attr("fill", color)
        .attr("r", circleRadius)
        .attr("cx", (d) => x(d.date))
        .attr("cy", (d) => y(d.balance));
}
