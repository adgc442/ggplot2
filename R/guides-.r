
## syntax sugar for + guides(XXX=YYY) as labs(XXX=YYY)
guides <- function(...) {
  args <- list(...)
  if (is.list(args[[1]]) && !inherits(args[[1]], "guide")) args <- args[[1]]
  args <- rename_aes(args)
  structure(args, class = "guides")
}

update_guides <- function(p, guides) {
  p <- plot_clone(p)
  p + opts(guides = guides)
}


## builing guides - called in ggplotGrob (plot-render.r)
##
## the procedure is as followings:
##
## 1. guides_train()
##      train each scale and generate guide definition for all guides
##      here, one gdef for one scale
##
## 2. guides_merge()
##      merge gdefs if they are overlayed
##      number of gdefs may be less than number of scales
##
## 3. guides_geom()
##      process layer information and generate geom info.
##
## 4. guides_gengrob()
##      generate ggrob from each gdef
##      one ggrob for one gdef
##
## 5. guides_build()
##      arrange all ggorbs

build_guides <- function(scales, layers, default_mapping, theme) {

  ## set themes w.r.t. guides
  ## should these theme$legend.XXX be renamed to theme$guide.XXX ?
  
  ## by default, guide boxes are vertically aligned
  theme$legend.box <- theme$legend.box %||% "vertical"

  ## size of key (also used for bar in colorbar guide)
  theme$legend.key.width <- theme$legend.key.width %||% theme$legend.key.size
  theme$legend.key.height <- theme$legend.key.height %||% theme$legend.key.size

  ## by default, direction of each guide depends on the position of the guide.
  theme$legend.direction <-
    theme$legend.direction %||%
    if (length(theme$legend.position) == 1 && theme$legend.position %in% c("top", "bottom", "left", "right"))
      switch(theme$legend.position[1], top =, bottom = "horizontal", left =, right = "vertical")
    else
      "vertical"

  ## justification of legend boxes
  theme$legend.box.just <-
    theme$legend.box.just %||%
    if (length(theme$legend.position) == 1 && theme$legend.position %in% c("top", "bottom", "left", "right"))
      switch(theme$legend.position, bottom =, top = c("center", "top"), left =, right = c("left", "top"))
    else
      c("center", "center")

  ## scales -> data for guides
  gdefs <- guides_train(scales = scales, theme = theme)
  if (length(gdefs) == 0) return(zeroGrob())

  ## merge overlay guides
  gdefs <- guides_merge(gdefs)

  ## process layer information
  gdefs <- guides_geom(gdefs, layers, default_mapping)

  ## generate grob of each guides
  ggrobs <- guides_gengrob(gdefs, theme)

  ## build up guides
  grobs <- guides_build(ggrobs, theme)

  grobs
}

## validate guide object
validate_guide <- function(guide) {
  ## if guide is specified by character, then find the corrsponding guide
  if (is.character(guide))
    match.fun(paste("guide_", guide, sep=""))()
  else if (inherits(guide, "guide"))
    guide
  else
    stop("Unknown guide: ", guide)
}

## train each scale in scales and generate the definition of guide
guides_train <- function(scales, theme) {

  gdefs <- list()
  for(scale in scales$scales) {

    ## guides(XXX) is stored in theme$guides[[XXX]],
    ## which is prior to scale_ZZZ(guide=XXX)
    ## guide is determined in order of:
    ##   + guides(XXX) > + scale_ZZZ(guide=XXX) > default(i.e., legend)
    output <- scale$aesthetics[1]
    guide <- theme$guides[[output]] %||% scale$guide 

    ## this should be changed to testing guide == "none"
    ## scale$legend is backward compatibility
    ## if guides(XXX=FALSE), then scale_ZZZ(guides=XXX) is discarded.
    if (guide=="none" || (is.logical(guide) && !guide)) next
    if (!scale$legend || is.null(scale_limits(scale))) next ## for backward compatibility

    ## check the validity of guide.
    ## if guide is character, then find the guide object
    guide <- validate_guide(guide)

    ## check the consistency of the guide and scale.
    if (guide$available_aes != "any" && ! scale$aesthetics %in% guide$available_aes)
      stop (paste("Guide '", guide$name, "' cannot be used for '", scale$aesthetics, "'.", sep=""))

    ## title of this grob
    if (is.waive(guide$title)) guide$title <- scale$name %||% theme$labels[[output]]

    ## direction of this grob
    guide$direction <- guide$direction %||% theme$legend.direction

    ## each guide object trains scale within the object,
    ## so Guides (i.e., the container of guides) need not to know about them
    guide <- guide_train(guide, scale)

    if (!is.null(guide)) gdefs[[length(gdefs)+1]] <- guide
  }
  gdefs
}

## merge overlapped guides
guides_merge <- function(gdefs) {
  ## split gdefs based on hash, and apply Reduce (guide_merge) to each gdef groug.
  tapply(gdefs, sapply(gdefs, function(g)g$hash), function(gs)Reduce(guide_merge, gs))
}

## process layer information
guides_geom <- function(gdefs, layers, default_mapping) {
  lapply(gdefs, guide_geom, layers, default_mapping)
}

## generate grob from each gdef (needs to write this function?)
guides_gengrob <- function(gdefs, theme) {
  ## common drawing process for all guides
  gdefs <- lapply(gdefs,
    function(g) {
      g$title.position <- g$title.position %||% switch(g$direction, vertical="top", horizontal="left")
      if (!g$title.position %in% c("top", "bottom", "left", "right")) stop("title position \"", g$title.position, "\" is invalid")
      g
    })
  
  lapply(gdefs, guide_gengrob, theme)
}

## build up all guide boxes into one guide-boxes.
guides_build <- function(ggrobs, theme) {

  n <- length(ggrobs)
  space <- unit(0.25, "lines")
  widths <- do.call("unit.c", lapply(ggrobs, function(g)sum(g$widths)))
  heights <- do.call("unit.c", lapply(ggrobs, function(g)sum(g$heights)))

  ## setting that is different for vergical and horizontal guide-boxes.
  switch(theme$legend.box,
    horizontal = {
      box_nrow <- 1
      box_ncol <- n
      twidths <- widths
      theights <- gheight <- max(heights)
      spacefun <- gtable_add_col_space
    },
    vertical = {
      box_nrow <- n
      box_ncol <- 1
      twidths <- gwidth <- max(widths)
      theights <- heights
      spacefun <- gtable_add_row_space
    })

  ## make gtable for the guide-boxes
  lay <- data.frame(l = seq(box_ncol), t = seq(box_nrow), r = seq(box_ncol), b = seq(box_nrow),
                    name = paste("guide-", seq(n), sep = ""),
                    clip = FALSE)
  guides <- gtable(lapply(ggrobs, gtable_gTree), lay, twidths, theights)

  ## add space between the guide-boxes.
  guides <- spacefun(guides, space)

  ## add margins around the guide-boxes.
  guides <- gtable_add_cols(guides, space, pos = 0)
  guides <- gtable_add_cols(guides, space, pos = ncol(guides))
  guides <- gtable_add_rows(guides, space, pos = 0)
  guides <- gtable_add_rows(guides, space, pos = nrow(guides))

  ## dims of the guide-boxes, used in ggplotGrob()
  gw <- sum(guides$widths)
  gh <- sum(guides$heights)

  ## make gTree
  guides <- gtable_gTree(guides)
  guides$width <- gw
  guides$height <- gh

  ## set justification of the guide-boxes
  ## should be there options for this, e.g., guide.box.just  = c("right", "bottom") ?
  for (i in seq(n)) guides$children[[i]]$childrenvp$parent$layout$valid.just <- valid.just(theme$legend.box.just)
  guides
}

## S3 dispatch
guide_train <- function(...) UseMethod("guide_train")
guide_merge <- function(...) UseMethod("guide_merge")
guide_geom <- function(...) UseMethod("guide_geom")
guide_gengrob <- function(...) UseMethod("guide_gengrob")
