function ggplot(dp, directory)
  DFres = dp.DF
  DF = dp.data.DF
  @rput DF
  @rput DFres
  @rput directory
  R"""
  library(ggplot2)
  library(cowplot)
  g <- ggplot(DFres, aes(x = x, y = mean)) +
  geom_histogram(data = DF, aes(x = VAF, y = ..density..), bins = 100,   fill = "gray68") +
  geom_line(col = "lightblue4", size = 1.0, alpha = 1.0) +
  geom_ribbon(aes(ymin = lq, ymax = uq), size = 0.2, col = "lightblue4", fill = "lightblue3", alpha = 0.7) +
  xlab("VAF") +
  ylab("Density")

  save_plot(filename = directory, plot = g)

  g

  """

end
