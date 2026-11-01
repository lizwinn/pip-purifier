# /// script
# requires-python = ">=3.12"
# dependencies = ["six==1.17.0", "packaging==25.0"]
# ///
import packaging
import six

print(f"script six={six.__version__} packaging={packaging.__version__}")
