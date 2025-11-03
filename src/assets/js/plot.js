function initPlotComponent() {
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
                this.$watch('plotData', (data) => {
                    if (data) {
                        this.renderPlotData(data);
                    }
                });

                this.$watch('plotChanges', (data) => {
                    if (data) {
                        this.renderPlotChanges(data);
                    }
                });
            },

            renderPlotChanges(alpineData) {
                const data = [];

                alpineData.forEach((item) => {
                    data.push({
                        period: new Date(item.period),
                        currency: item.currency,
                        account: item.account,
                        balance: item.balance,
                        balance_rendered: item.balance_rendered,
                    });
                });

                // Group data by period, then by currency
                const dataByPeriod = d3.group(data, d => d.period);
                const periods = Array.from(dataByPeriod.keys()).sort((a, b) => a - b);

                const currencies = Array.from(new Set(data.map(d => d.currency))).sort();
                const accounts = Array.from(new Set(data.map(d => d.account))).sort();

                const currencyColorScale = d3.scaleOrdinal()
                    .domain(currencies)
                    .range(["#808080"]);

                const accountColorScale = d3.scaleOrdinal()
                    .domain(accounts)
                    .range([
                        ...d3.schemePaired,
                        ...d3.schemeObservable10,
                    ]);

                const width = document.querySelector("#d3 svg").clientWidth;
                const height = width / 5;

                svg.attr("viewBox", `${-margin.left} ${-margin.top} ${width + margin.left + margin.right} ${height + margin.top + margin.bottom}`);

                xGroup.attr("transform", `translate(0,${height})`);

                // Calculate stacked data for each period/currency
                const stackedData = [];
                periods.forEach(period => {
                    const periodData = dataByPeriod.get(period);
                    const byCurrency = d3.group(periodData, d => d.currency);

                    currencies.forEach(currency => {
                        const currencyData = byCurrency.get(currency) || [];

                        // Separate positive and negative balances
                        const positive = currencyData.filter(d => d.balance >= 0).sort((a, b) => b.balance - a.balance);
                        const negative = currencyData.filter(d => d.balance < 0).sort((a, b) => a.balance - b.balance);

                        // Calculate stack positions for positive
                        let yPos = 0;
                        positive.forEach(d => {
                            stackedData.push({
                                period: period,
                                currency: currency,
                                account: d.account,
                                balance: d.balance,
                                balance_rendered: d.balance_rendered,
                                y0: yPos,
                                y1: yPos + d.balance
                            });
                            yPos += d.balance;
                        });

                        // Calculate stack positions for negative
                        let yNeg = 0;
                        negative.forEach(d => {
                            stackedData.push({
                                period: period,
                                currency: currency,
                                account: d.account,
                                balance: d.balance,
                                balance_rendered: d.balance_rendered,
                                y0: yNeg + d.balance,
                                y1: yNeg
                            });
                            yNeg += d.balance;
                        });

                        // Store sum for this period/currency
                        if (currencyData.length > 0) {
                            const sum = currencyData.reduce((acc, d) => acc + d.balance, 0);
                            stackedData.push({
                                period: period,
                                currency: currency,
                                account: '__sum__',
                                sum: sum,
                                y0: sum,
                                y1: sum
                            });
                        }
                    });
                });

                // Create scales
                const x = d3.scaleBand()
                    .domain(periods.map(p => p.getTime()))
                    .range([0, width])
                    .padding(0.15);

                // Calculate y domain to include all stacked values
                const allY = stackedData.flatMap(d => [d.y0, d.y1]);
                const y = d3.scaleLinear()
                    .domain([Math.min(0, d3.min(allY)), Math.max(0, d3.max(allY))])
                    .nice()
                    .range([height, 0]);

                // Clear previous chart
                chart.selectAll("*").remove();

                // Draw striped background bands
                periods.forEach((period) => {
                    // Get sums for this period
                    const periodSums = stackedData.filter(d =>
                        d.account === '__sum__' &&
                        d.period.getTime() === period.getTime()
                    );

                    chart.append("rect")
                        .attr("x", x(period.getTime()))
                        .attr("y", 0)
                        .attr("width", x.bandwidth())
                        .attr("height", height)
                        .attr("fill", "#d3d3d3")
                        .attr("opacity", 0.2)
                        .on("mouseover", function(event) {
                            // Build tooltip text with all currency balances
                            const tooltipText = periodSums
                                .map(s => `${s.sum.toFixed(2)} ${s.currency}`)
                                .join(', ');

                            tooltip
                                .style("display", "block")
                                .style("left", `${event.pageX + 10}px`)
                                .style("top", `${event.pageY - 10}px`)
                                .text(`${period.toISOString().split('T')[0]}: ${tooltipText}`);
                        })
                        .on("mousemove", function(event) {
                            tooltip
                                .style("left", `${event.pageX + 10}px`)
                                .style("top", `${event.pageY - 10}px`);
                        })
                        .on("mouseout", function() {
                            tooltip.style("display", "none");
                        });
                });

                // Calculate bar width per currency
                const barWidth = 0.8 * x.bandwidth() / currencies.length;
                const start = 0.1 * x.bandwidth()
                const gap = 0.05 * x.bandwidth()

                // Draw stacked rectangles
                stackedData.filter(d => d.account !== '__sum__').forEach(d => {
                    const currencyIndex = currencies.indexOf(d.currency);
                    const xPos = x(d.period.getTime()) + start + currencyIndex * barWidth;

                    chart.append("rect")
                        .attr("class", `account-rect account-${d.account.replace(/[^a-zA-Z0-9]/g, '-')}`)
                        .attr("data-account", d.account)
                        .attr("x", xPos + gap)
                        .attr("y", y(d.y1))
                        .attr("width", barWidth - 2 * gap)
                        .attr("height", Math.abs(y(d.y0) - y(d.y1)))
                        .attr("fill", accountColorScale(d.account))
                        .on("mouseover", function(event) {
                            const account = d.account;

                            // Highlight all rectangles for this account
                            chart.selectAll(`.account-rect[data-account="${account}"]`)
                                .attr("fill", "url(#stripes)");

                            // Show tooltip
                            tooltip
                                .style("display", "block")
                                .style("left", `${event.pageX + 10}px`)
                                .style("top", `${event.pageY}px`)
                                .text(`${d.account}: ${d.balance_rendered} ${d.currency}`);
                        })
                        .on("mousemove", function(event) {
                            tooltip
                                .style("left", `${event.pageX + 10}px`)
                                .style("top", `${event.pageY}px`);
                        })
                        .on("mouseout", function() {
                            // Restore all rectangles
                            chart.selectAll(".account-rect")
                                .attr("fill", function() { return accountColorScale(d3.select(this).attr("data-account")); });

                            // Hide tooltip
                            tooltip.style("display", "none");
                        });
                });

                // Draw sum lines
                stackedData.filter(d => d.account === '__sum__').forEach(d => {
                    const currencyIndex = currencies.indexOf(d.currency);
                    const xPos = x(d.period.getTime()) + start + currencyIndex * barWidth;

                    chart.append("line")
                        .attr("x1", xPos)
                        .attr("x2", xPos + barWidth)
                        .attr("y1", y(d.sum))
                        .attr("y2", y(d.sum))
                        .attr("stroke", "black")
                        .attr("stroke-width", 2)
                        .append("title");
                });

                // Draw zero line
                chart.append("line")
                    .attr("x1", 0)
                    .attr("x2", width)
                    .attr("y1", y(0))
                    .attr("y2", y(0))
                    .attr("stroke", "black")
                    .attr("stroke-width", 1)
                    .attr("opacity", 0.5);

                // Render axes
                // Calculate how many labels we can fit without overlap
                const labelWidth = 80; // Approximate width of date label
                const maxLabels = Math.floor(width / labelWidth);
                const skipInterval = Math.max(1, Math.ceil(periods.length / maxLabels));

                xGroup.call(d3.axisBottom(x).tickFormat((d, i) => {
                    if (i % skipInterval === 0) {
                        const date = new Date(+d);
                        return d3.timeFormat("%Y-%m-%d")(date);
                    }
                    return "";
                }));

                yGroup.call(d3.axisLeft(y).tickFormat(d3.format("~s")));

                // Render legend for currencies
                renderLegend(currencies, currencyColorScale);
            },

            renderPlotData(alpineData) {
                const data = [];

                alpineData.forEach((txn) => {
                    data.push({
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
                    renderCurrency(currency, colorScale(currency), chart, dataByCurrency.get(currency), x, y);
                });

                // Render legend
                renderLegend(currencies, colorScale);

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
}

function renderLegend(currencies, colorScale) {
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

function renderCurrency(currency, color, chart, data, x, y) {
    var desaturated = d3.hsl(color);
    desaturated.s = 0.0;
    desaturated.l += 0.1;

    const lineWidth = 1.5;
    const circleRadius = 1.5;

    chart
        .selectAll(`.vertical-${currency}`)
        .data(data.slice(1)) // From second point onward
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
        .data(data) // One less than points
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
        .data(data)
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
